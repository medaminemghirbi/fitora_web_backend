module Api
  module V1
    class ClientsController < BaseController
      before_action :require_company!
      before_action -> { require_capability!(:clients) }
      # Taking someone off the gym's books (and, for their last gym, erasing
      # them) is the admin's decision.
      before_action :require_admin!, only: :destroy
      before_action :set_client, only: [ :show, :update, :invite, :destroy ]
      # This controller's errors also carry `message`, refused or invalid alike.
      rescue_from ApplicationRecord::Refused, with: ->(refusal) { render_error(refusal.message) }
      rescue_from ActiveRecord::RecordInvalid, with: ->(invalid) {
        messages = invalid.record.errors.full_messages
        render_error(messages.first, errors: messages)
      }

      STATUS_FILTERS = %w[active inactive contract_active contract_expired no_contract].freeze

      # Sort key → the columns it orders on. Anything else falls back to name.
      SORTS = {
        "name" => %w[clients.first_name clients.last_name],
        "joined" => %w[memberships.joined_at],
        "created" => %w[clients.created_at]
      }.freeze

      # Between two invitations to the same person, so a double click does
      # not send two emails.
      INVITE_COOLDOWN = 60.seconds

      # GET /api/v1/clients?search=&status=&page=
      # status: active | inactive | contract_active | contract_expired | no_contract
      #
      # Beyond the search box, the list narrows on the plan someone holds, the
      # activity it covers, their gender and when they joined, and it orders on
      # a whitelisted column. Everything here is optional and composes: the
      # counts are computed AFTER the narrowing, so the status pills say how
      # many rows each status would return for the filters already set.
      def index
        narrowed = narrow(current_company.clients.search(params[:search]))
        clients = status_scope(narrowed, params[:status]).order(Arel.sql(order_clause))

        if params[:format] == "csv"
          # The whole member file leaving the building: admin only.
          return render_forbidden unless current_user.admin?

          send_data clients_csv(clients), filename: "clients-#{Date.current}.csv"
        else
          page = paginate(clients).to_a
          visits = last_visits_for(page)
          context = ClientSerializer.page_context(page, current_company)

          render json: {
            clients: page.map { |c|
              ClientSerializer.new(
                c, company: current_company, last_visit_at: visits[c.id],
                membership: context[:memberships][c.id], current_contract: context[:current_contracts][c.id]
              ).as_json
            },
            meta: pagination_meta(clients),
            counts: status_counts(narrowed)
          }
        end
      end

      # When each member last turned up, for the whole page in one query.
      # Asking per member would be twenty aggregates for twenty rows — the
      # kind of N+1 that only shows up once a gym has real traffic.
      def last_visits_for(page)
        return {} if page.empty?

        Booking.confirmed
               .joins(:session)
               .where(client_id: page.map(&:id), sessions: { company_id: current_company.id })
               .group(:client_id)
               .maximum("sessions.starts_at")
      end

      # GET /api/v1/clients/:id
      def show
        render json: {
          client: ClientSerializer.new(@client, detailed: true, company: current_company).as_json,
          contracts: @client.contracts_for(current_company).for_serializer.order(created_at: :desc).map { |m| ContractSerializer.new(m).as_json },
          bookings: @client.bookings_for(current_company).includes(session: [ :activity, :coach ]).order(created_at: :desc).limit(20).map { |b| BookingSerializer.new(b).as_json },
          payments: @client.payments_for(current_company).recent.limit(20).map { |p| PaymentSerializer.new(p).as_json }
        }
      end

      # POST /api/v1/clients — adds someone to THIS gym (Client.enrol!),
      # optionally selling them a plan and taking the money in the same
      # transaction, which is what actually happens at a front desk. A member
      # who exists but has no subscription because the plan had no price for
      # that activity is exactly the mess this avoids.
      def create
        return render_forbidden if subscription_params.present? && !capability?(:contracts)

        client = contract = nil
        ActiveRecord::Base.transaction do
          client = Client.enrol!(current_company, person: person_params, membership: membership_params)
          contract = sell_plan_to(client) if subscription_params.present?
        end

        AuditLog.record!(
          company: current_company, user: current_user,
          action: client.previously_new_record? ? "client.created" : "client.joined",
          auditable: client, metadata: { name: client.full_name }
        )
        render json: {
          client: ClientSerializer.new(client, company: current_company).as_json,
          contract: contract && ContractSerializer.new(contract).as_json,
          payment: contract && PaymentSerializer.new(contract.payments.first).as_json
        }, status: :created
      end

      # PATCH /api/v1/clients/:id
      #
      # What the gym wrote about the person lands on its own membership. The
      # person's name, email and phone are the gym's to change only while the
      # gym is the only one that knows them (Client#identity_shared_beyond?);
      # after that it can fill in what is blank, and anything else is refused
      # rather than silently dropped. No password is ever accepted here — see
      # #invite.
      def update
        changes = person_params.to_h
        if @client.identity_shared_beyond?(current_company) && (locked = locked_identity_changes(changes)).any?
          return render json: {
            error: "identity_locked",
            message: "This member's #{locked.map { |f| f.humanize.downcase }.to_sentence} belong to their own Fitora account, so the gym can't change them.",
            errors: locked.map { |field| "#{field.humanize} is managed by the member" }
          }, status: :unprocessable_content
        end

        ActiveRecord::Base.transaction do
          @client.membership_for(current_company).update!(membership_params) if membership_params.any?
          @client.update!(changes)
        end

        AuditLog.record!(
          company: current_company, user: current_user, action: "client.updated",
          auditable: @client, metadata: { name: @client.full_name }
        )
        render json: { client: ClientSerializer.new(@client, company: current_company).as_json }
      end

      # POST /api/v1/clients/:id/invite — switches the member's own app on by
      # emailing them a link to choose their password. The gym never picks,
      # sees or resets it; a member who forgets it uses "forgot password"
      # like anyone else.
      def invite
        unless current_company.member_app?
          return render json: {
            error: "member_app_not_included",
            message: "The member app comes with Fitora Pro."
          }, status: :forbidden
        end
        return render_error("This member has no email address to invite.") if @client.email.blank?
        return render_error("This member already has access to the app.", code: "already_enabled") if @client.login_enabled?
        if @client.invitation_sent_at && @client.invitation_sent_at > INVITE_COOLDOWN.ago
          return render_error("An invitation was just sent. Try again in a minute.", code: "invitation_recently_sent")
        end

        raw = @client.generate_invitation_token!
        AccountMailer.member_invitation(@client, current_company, raw).deliver_later
        AuditLog.record!(
          company: current_company, user: current_user, action: "client.invited",
          auditable: @client, metadata: { name: @client.full_name }
        )
        render json: { client: ClientSerializer.new(@client, company: current_company).as_json }, status: :accepted
      end

      # DELETE /api/v1/clients/:id — see Client#remove_from!.
      def destroy
        name = @client.full_name
        anonymised = @client.remove_from!(current_company)

        AuditLog.record!(
          company: current_company, user: current_user, action: "client.removed",
          auditable: @client, metadata: { name: name, anonymised: anonymised }
        )
        head :no_content
      end

      private

      def set_client
        @client = current_company.clients.find(params[:id])
      end

      def sell_plan_to(client)
        plan = current_company.contract_types.find_by(id: subscription_params[:contract_type_id])
        raise ApplicationRecord::Refused, "Plan not found" if plan.nil?

        # A pack is sold in place of an activity — one or the other.
        pack = nil
        activity = nil
        if subscription_params[:pack_id].present?
          pack = current_company.packs.active.find_by(id: subscription_params[:pack_id])
          raise ApplicationRecord::Refused, "Pack not found" if pack.nil?
        else
          activity = current_company.activities.find_by(id: subscription_params[:activity_id])
          raise ApplicationRecord::Refused, "Activity not found" if activity.nil?
        end

        Contract.sell!(
          client: client, contract_type: plan, activity: activity, pack: pack, created_by: current_user,
          starts_on: subscription_params[:starts_on].presence&.to_date || Date.current,
          discount: subscription_params[:discount].presence || 0,
          collect_payment: subscription_params[:collect_payment],
          payment_method: subscription_params[:payment_method],
          payment_notes: subscription_params[:payment_notes]
        )
      end

      # The advanced filters, each a no-op when its parameter is absent.
      def narrow(scope)
        scope = scope.where(id: plan_holders.select(:client_id)) if params[:contract_type_id].present?
        scope = scope.where(id: activity_holders.select(:client_id)) if params[:activity_id].present?
        scope = scope.where(memberships: { gender: params[:gender] }) if params[:gender].present?

        from = parse_date(params[:joined_from])
        to = parse_date(params[:joined_to])
        scope = scope.where(memberships: { joined_at: from.beginning_of_day.. }) if from
        scope = scope.where(memberships: { joined_at: ..to.end_of_day }) if to
        scope
      end

      def plan_holders
        company_contracts.where(contract_type_id: params[:contract_type_id])
      end

      # An all-access contract (activity_id NULL) covers every activity its
      # plan is priced for, and a pack contract every activity in its pack,
      # so filtering on an activity has to find those too — see
      # Contract#covers_activity?, which is the same rule.
      def activity_holders
        id = params[:activity_id]
        all_access_plans = current_company.contract_types
                                          .joins(:contract_type_activities)
                                          .where(contract_type_activities: { activity_id: id })
        packs_with_it = PackActivity.where(activity_id: id).select(:pack_id)

        company_contracts.where(activity_id: id)
                         .or(company_contracts.where(activity_id: nil, pack_id: nil, contract_type_id: all_access_plans))
                         .or(company_contracts.where(pack_id: packs_with_it))
      end

      def parse_date(value)
        Date.parse(value.to_s)
      rescue Date::Error, TypeError
        nil
      end

      # A whitelist, because both halves come off a query string. "name" is two
      # columns, so the direction has to be spelled onto each of them.
      def order_clause
        direction = params[:direction] == "desc" ? "DESC" : "ASC"
        columns = SORTS.fetch(params[:sort], SORTS.fetch("name"))
        columns.map { |column| "#{column} #{direction}" }.join(", ")
      end

      # "Active" here means active AT THIS GYM (the membership), and every
      # contract test is restricted to this gym's contracts — a person who is
      # subscribed elsewhere must not read as subscribed here.
      def status_scope(scope, status)
        case status
        when "active" then scope.where(memberships: { active: true })
        when "inactive" then scope.where(memberships: { active: false })
        when "contract_active" then scope.where(id: company_contracts.currently_active.select(:client_id))
        when "contract_expired" then scope.where(id: company_contracts.expired.select(:client_id))
        when "no_contract" then scope.where.not(id: company_contracts.select(:client_id))
        else scope
        end
      end

      def company_contracts
        current_company.contracts
      end

      # What each status would return for the CURRENT search — the filter rail
      # shows these next to its options, so they follow the search box and not
      # the status already picked.
      def status_counts(searched)
        STATUS_FILTERS.index_with { |status| status_scope(searched, status).count }
                      .merge("all" => searched.count)
      end

      def clients_csv(clients)
        joined = current_company.memberships.pluck(:client_id, :joined_at, :active).to_h { |id, at, on| [ id, [ at, on ] ] }
        CsvSafe.generate do |csv|
          csv << [ "First name", "Last name", "Email", "Phone", "Active", "Joined at" ]
          clients.find_each do |c|
            at, on = joined[c.id]
            csv << [ c.first_name, c.last_name, c.email, c.phone, on, at ]
          end
        end
      end

      def subscription_params
        return {} if params[:subscription].blank?

        params.require(:subscription).permit(
          :contract_type_id, :activity_id, :pack_id, :starts_on, :discount,
          :collect_payment, :payment_method, :payment_notes
        )
      end

      def membership_params
        client_params.slice(:notes, :active, *Membership::PROFILE_FIELDS).to_h.symbolize_keys
      end

      def person_params
        client_params.slice(*Client::IDENTITY_FIELDS)
      end

      # The identity fields this edit would change on a person the gym no
      # longer owns. Filling a blank is not a change; neither is sending the
      # value back as it already is.
      def locked_identity_changes(changes)
        changes.select do |field, value|
          current = @client.public_send(field)
          current.present? && normalize_identity(field, value) != normalize_identity(field, current)
        end.keys
      end

      def normalize_identity(field, value)
        normalized = value.to_s.strip
        field == "email" ? normalized.downcase : normalized
      end

      def render_error(message, code: nil, errors: [ message ])
        render json: { error: code || message, message: message, errors: errors }, status: :unprocessable_content
      end

      def client_params
        params.require(:client).permit(
          :first_name, :last_name, :email, :phone, :date_of_birth, :gender,
          :address, :emergency_contact_name, :emergency_contact_phone, :notes, :active,
          :health_notes, :waiver_signed_on
        )
      end
    end
  end
end
