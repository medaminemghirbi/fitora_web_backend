module Api
  module V1
    class ContractsController < BaseController
      before_action :require_company!
      before_action -> { require_capability!(:contracts) }
      before_action :set_contract, only: [ :show, :update, :renew, :cancel, :pause, :resume, :destroy, :receipt, :agreement ]

      # GET /api/v1/contracts — the company's contracts, filterable by
      # status, payment and/or contract_type_id.
      #
      # status=expiring is not one of Contract's four states: it is "active,
      # and running out within the month", which is what the dashboard sends
      # people here to act on.
      def index
        searched = searched_scope
        contracts = searched
        contracts = apply_status(contracts, params[:status]) if params[:status].present?
        contracts = apply_payment(contracts, params[:payment]) if params[:payment].present?
        contracts = contracts.where(contract_type_id: params[:contract_type_id]) if params[:contract_type_id].present?

        render json: {
          contracts: paginate(contracts).map { |m| ContractSerializer.new(m).as_json },
          meta: pagination_meta(contracts),
          counts: status_counts(searched),
          plan_counts: plan_counts(searched),
          totals: portfolio_totals(searched)
        }
      end

      # GET /api/v1/contracts/:id
      def show
        render json: { contract: ContractSerializer.new(@contract).as_json }
      end

      # POST /api/v1/contracts — staff gives a client a contract
      def create
        client, plan, activity, pack = sale_parties
        return if performed?

        contract = Contract.sell!(
          client: client, contract_type: plan, activity: activity, pack: pack, created_by: current_user,
          starts_on: params[:starts_on].present? ? Date.parse(params[:starts_on]) : Date.current,
          discount: params[:discount].presence || 0,
          collect_payment: params[:collect_payment], payment_method: params[:payment_method]
        )

        AuditLog.record!(
          company: current_company, user: current_user, action: "contract.created",
          auditable: contract, metadata: { client: client.full_name, plan: plan.name }
        )
        render json: {
          contract: ContractSerializer.new(contract).as_json,
          payment: PaymentSerializer.new(contract.payments.first).as_json
        }, status: :created
      end

      # PATCH /api/v1/contracts/:id — edit this term (dates, discount)
      def update
        @contract.update_term!(starts_on: params[:starts_on], expires_on: params[:expires_on], discount: params[:discount])
        render json: { contract: ContractSerializer.new(@contract.reload).as_json }
      end

      # POST /api/v1/contracts/:id/renew — sells the next term, a new
      # contract linked to this one. Same formule unless contract_type_id
      # (and activity_id or pack_id) name another: renewing is when a member
      # moves to a different formule.
      def renew
        plan, activity, pack = renewal_formule
        return if performed?

        renewal = @contract.renew!(contract_type: plan, activity: activity, pack: pack, created_by: current_user)
        AuditLog.record!(
          company: current_company, user: current_user, action: "contract.renewed",
          auditable: renewal, metadata: { client: @contract.client.full_name, plan: plan.name, renewed_from: @contract.id }
        )
        render json: { contract: ContractSerializer.new(renewal).as_json }, status: :created
      end

      # POST /api/v1/contracts/:id/cancel
      def cancel
        @contract.cancel!
        AuditLog.record!(
          company: current_company, user: current_user, action: "contract.cancelled",
          auditable: @contract, metadata: { client: @contract.client.full_name, plan: @contract.contract_type.name }
        )
        render json: { contract: ContractSerializer.new(@contract.reload).as_json }
      end

      # POST /api/v1/contracts/:id/pause — membership on hold (Contract#pause!)
      def pause
        @contract.pause!
        AuditLog.record!(
          company: current_company, user: current_user, action: "contract.paused",
          auditable: @contract, metadata: { client: @contract.client.full_name, plan: @contract.contract_type.name }
        )
        render json: { contract: ContractSerializer.new(@contract.reload).as_json }
      end

      # POST /api/v1/contracts/:id/resume — end the hold, give the time back
      def resume
        @contract.resume!
        AuditLog.record!(
          company: current_company, user: current_user, action: "contract.resumed",
          auditable: @contract, metadata: { client: @contract.client.full_name, plan: @contract.contract_type.name }
        )
        render json: { contract: ContractSerializer.new(@contract.reload).as_json }
      end

      # DELETE /api/v1/contracts/:id — only once cancelled, so this is
      # never how history disappears by accident: cancel (soft, reversible
      # by re-subscribing) is the everyday action; destroy is a deliberate
      # second step for actually clearing clutter out of a client's history.
      def destroy
        unless @contract.cancelled?
          return render json: { error: "Only cancelled contracts can be deleted" }, status: :unprocessable_content
        end

        metadata = { client: @contract.client.full_name, plan: @contract.contract_type.name }
        @contract.destroy!
        AuditLog.record!(company: current_company, user: current_user, action: "contract.deleted", auditable: @contract, metadata: metadata)

        head :no_content
      end

      # GET /api/v1/contracts/:id/receipt — available to anyone who can
      # already see this contract (require_capability!(:contracts)).
      def receipt
        pdf_data = Receipts::ContractPdf.call(contract: @contract)

        send_data pdf_data,
                   filename: "facture-#{@contract.client.full_name.parameterize}-#{@contract.invoice_ref.downcase}.pdf",
                   type: "application/pdf",
                   disposition: "attachment"
      end

      # GET /api/v1/contracts/:id/agreement — the abonnement contract itself,
      # signed by the gym with its default signature (Settings), for the
      # member to sign in turn.
      def agreement
        pdf_data = Receipts::ContractAgreementPdf.call(contract: @contract)

        send_data pdf_data,
                  filename: "contrat-#{@contract.client.full_name.parameterize}-#{@contract.invoice_ref.downcase}.pdf",
                  type: "application/pdf",
                  disposition: "attachment"
      end

      private

      # Who is buying, which plan, for which activity — each this gym's own,
      # or a 404 naming which one was not found.
      def sale_parties
        client = current_company.clients.find_by(id: params[:client_id])
        return render(json: { error: "Client not found" }, status: :not_found) if client.nil?

        formule = formule_from_params
        return if performed?

        [ client, *formule ]
      end

      # The formule a renewal moves onto: the one named in the request, or —
      # when none is — the one the renewed contract is already on.
      def renewal_formule
        return [ @contract.contract_type, @contract.activity, @contract.pack ] if params[:contract_type_id].blank?

        formule_from_params
      end

      # [plan, activity, pack] from contract_type_id + activity_id / pack_id.
      def formule_from_params
        plan = current_company.contract_types.active.find_by(id: params[:contract_type_id])
        return render(json: { error: "Contract plan not found" }, status: :not_found) if plan.nil?

        # A pack is sold in place of an activity — one or the other.
        if params[:pack_id].present?
          pack = current_company.packs.active.find_by(id: params[:pack_id])
          return render(json: { error: "Pack not found" }, status: :not_found) if pack.nil?

          return [ plan, nil, pack ]
        end

        activity = current_company.activities.find_by(id: params[:activity_id])
        return render(json: { error: "Activity not found" }, status: :not_found) if activity.nil?

        [ plan, activity, nil ]
      end

      # The list's status filter, and its counts, both read each contract's
      # own state — the list holds no history (see #searched_scope), so
      # that is the term in force or a renewal queued behind it.
      def apply_status(scope, status)
        return expiring_scope(scope) if status == "expiring"
        return paused_scope(scope) if status == "paused"

        scope.where(status: status)
      end

      # The "Non réglés" filter has to return exactly what its count promises,
      # so it goes through the same scope the count is built from.
      def apply_payment(scope, payment)
        return unpaid_scope(scope) if payment == "unpaid"

        scope.active.where(payment_status: payment)
      end

      # "Running out" means the gym's COVER runs out — a contract already
      # renewed is not work, even though the term in force still ends this
      # month.
      def expiring_scope(scope)
        scope.active.not_renewed.where(paused_at: nil, expires_at: Time.current..30.days.from_now)
      end

      # On hold (Contract#pause!) — still `active`, so not a state of its
      # own, but the one list a studio checks to bring people back.
      def paused_scope(scope)
        scope.active.where.not(paused_at: nil)
      end

      # Money owed — on the term in force or on a renewal queued behind it
      # (a renewal is sold unpaid).
      def unpaid_scope(scope)
        scope.active.unpaid
      end

      # The list is what the desk works from, so it leaves out history: a
      # term whose renewal has already started is behind the member, and
      # stays on their profile. What remains is the term in force and any
      # renewal queued behind it, each a row of its own with its own price
      # to collect.
      def searched_scope
        scope = current_company.contracts.not_superseded.for_serializer.order(created_at: :desc)
        return scope if params[:q].blank?

        t = "%#{params[:q].strip}%"
        scope.joins(:client).joins(:contract_type)
             .where("clients.first_name ILIKE :t OR clients.last_name ILIKE :t OR contract_types.name ILIKE :t " \
                    "OR contracts.invoice_ref ILIKE :t", t: t)
      end

      # What the filter rail and the stats strip read. Everything here follows
      # the search term but ignores the status/plan already picked, so the
      # numbers stay comparable while the operator clicks around.
      # The four contract states, plus the ones the filter rail offers that
      # are not states at all: everything, owed, running out, on hold.
      def status_counts(searched)
        searched.reorder(nil).group(:status).count
                .then { |by_status| Contract.statuses.keys.index_with { |status| by_status.fetch(status, 0) } }
                .merge(
                  "all" => searched.count,
                  "unpaid" => unpaid_scope(searched).count,
                  "expiring" => expiring_scope(searched).count,
                  "paused" => paused_scope(searched).count
                )
      end

      def plan_counts(searched)
        searched.reorder(nil).group(:contract_type_id).count
      end

      # The portfolio is what the ACTIVE contracts were sold for — the frozen
      # prices, never today's catalogue.
      #
      # The money figures are `revenue`, like the payments strip: whoever only
      # sells contracts still sees how many are about to expire, which is
      # work to do, but not what the portfolio is worth.
      def portfolio_totals(searched)
        totals = { expiring_soon: expiring_scope(searched).count }
        return totals unless capability?(:revenue)

        active = searched.active
        value = active.sum(:final_price)
        count = active.count
        totals.merge(
          portfolio_value: value.to_f,
          average_basket: count.positive? ? (value.to_f / count).round(2) : 0.0,
          unpaid_value: unpaid_scope(searched).sum(:final_price).to_f
        )
      end

      def set_contract
        @contract = current_company.contracts.find(params[:id])
      end
    end
  end
end
