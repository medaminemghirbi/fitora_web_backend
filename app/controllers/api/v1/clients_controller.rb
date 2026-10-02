module Api
  module V1
    class ClientsController < BaseController
      before_action :require_company!
      before_action -> { require_capability!(:clients) }
      before_action :set_client, only: [ :show, :update, :invite, :destroy ]

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
          contracts: @client.contracts_for(current_company).includes(:contract_type).order(created_at: :desc).map { |m| ContractSerializer.new(m).as_json },
          bookings: @client.bookings_for(current_company).includes(session: [ :activity, :coach ]).order(created_at: :desc).limit(20).map { |b| BookingSerializer.new(b).as_json },
          payments: @client.payments_for(current_company).recent.limit(20).map { |p| PaymentSerializer.new(p).as_json }
        }
      end

      # POST /api/v1/clients — adds someone to THIS gym, optionally selling
      # them a plan in the same request. See Clients::Enrol.
      def create
        return render_forbidden if subscription_params.present? && !capability?(:contracts)

        result = Clients::Enrol.call(
          company: current_company, created_by: current_user,
          person: person_params, membership: membership_params, subscription: subscription_params
        )
        return render_error(result.error) unless result.success?

        client = result.client
        AuditLogs::Record.call(
          company: current_company, user: current_user,
          action: result.adopted ? "client.joined" : "client.created",
          auditable: client, metadata: { name: client.full_name }
        )
        render json: {
          client: ClientSerializer.new(client, company: current_company).as_json,
          contract: result.contract && ContractSerializer.new(result.contract).as_json,
          payment: result.payment && PaymentSerializer.new(result.payment).as_json
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
            message: "This member's #{locked.map { |f| f.humanize.downcase }.to_sentence} belong to their own Gymly account, so the gym can't change them.",
            errors: locked.map { |field| "#{field.humanize} is managed by the member" }
          }, status: :unprocessable_content
        end

        ActiveRecord::Base.transaction do
          @client.membership_for(current_company).update!(membership_params) if membership_params.any?
          @client.update!(changes)
        end

        AuditLogs::Record.call(
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
            message: "The member app comes with Gymly Pro."
          }, status: :forbidden
        end
        return render_error("This member has no email address to invite.") if @client.email.blank?
        return render_error("This member already has access to the app.", code: "already_enabled") if @client.login_enabled?
        if @client.invitation_sent_at && @client.invitation_sent_at > INVITE_COOLDOWN.ago
          return render_error("An invitation was just sent. Try again in a minute.", code: "invitation_recently_sent")
        end

        raw = @client.generate_invitation_token!
        AccountMailer.member_invitation(@client, current_company, raw).deliver_later
        AuditLogs::Record.call(
          company: current_company, user: current_user, action: "client.invited",
          auditable: @client, metadata: { name: @client.full_name }
        )
        render json: { client: ClientSerializer.new(@client, company: current_company).as_json }, status: :accepted
      end

      # DELETE /api/v1/clients/:id — see Clients::RemoveFromGym.
      def destroy
        name = @client.full_name
        result = Clients::RemoveFromGym.call(client: @client, company: current_company)
        return render_error(result.error) unless result.success?

        AuditLogs::Record.call(
          company: current_company, user: current_user, action: "client.removed",
          auditable: @client, metadata: { name: name, anonymised: result.anonymised }
        )
        head :no_content
      end

      private

      def set_client
        @client = current_company.clients.find(params[:id])
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
      # plan is priced for, so filtering on an activity has to find those too
      # — see Contract#covers_activity?, which is the same rule.
      def activity_holders
        id = params[:activity_id]
        all_access_plans = current_company.contract_types
                                          .joins(:contract_type_activities)
                                          .where(contract_type_activities: { activity_id: id })

        company_contracts.where(activity_id: id)
                         .or(company_contracts.where(activity_id: nil, contract_type_id: all_access_plans))
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
        when "contract_active" then scope.where(id: client_ids_with_period(current_company.contract_periods.merge(ContractPeriod.currently_active)))
        when "contract_expired" then scope.where(id: client_ids_with_period(expired_periods))
        when "no_contract" then scope.where.not(id: company_contracts.select(:client_id))
        else scope
        end
      end

      def company_contracts
        current_company.contracts
      end

      def expired_periods
        current_company.contract_periods.where(status: :expired)
      end

      # `periods` is always one of this company's own period scopes, so a
      # person's contracts at another gym can never match here.
      def client_ids_with_period(periods)
        company_contracts.where(id: periods.select(:contract_id)).select(:client_id)
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
          :contract_type_id, :activity_id, :starts_on, :discount,
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

      def render_error(message, code: nil)
        render json: { error: code || message, message: message, errors: [ message ] }, status: :unprocessable_content
      end

      def client_params
        params.require(:client).permit(
          :first_name, :last_name, :email, :phone, :date_of_birth, :gender,
          :address, :emergency_contact_name, :emergency_contact_phone, :notes, :active
        )
      end
    end
  end
end
