module Api
  module V1
    class ContractsController < BaseController
      # Contract#current_period, in SQL: the last period that has already
      # STARTED, and only when none has, the nearest upcoming one. Ordering
      # on the latest starts_at instead would let a renewal booked for next
      # month decide how the contract is filed today. Correlated on
      # contracts.id, so it only goes inside a query joined to contracts.
      CURRENT_PERIOD_SUBQUERY = <<~SQL.squish
        SELECT cp2.id FROM contract_periods cp2
        WHERE cp2.contract_id = contracts.id
        ORDER BY (COALESCE(cp2.starts_at, cp2.created_at) <= :now) DESC,
                 CASE WHEN COALESCE(cp2.starts_at, cp2.created_at) <= :now
                      THEN COALESCE(cp2.starts_at, cp2.created_at) END DESC,
                 CASE WHEN COALESCE(cp2.starts_at, cp2.created_at) > :now
                      THEN COALESCE(cp2.starts_at, cp2.created_at) END ASC,
                 cp2.created_at DESC
        LIMIT 1
      SQL

      before_action :require_company!
      before_action -> { require_capability!(:contracts) }
      before_action :set_contract, only: [ :show, :update, :renew, :cancel, :destroy, :receipt ]

      # GET /api/v1/contracts — the company's contracts, filterable by
      # status, payment and/or contract_type_id.
      #
      # status=expiring is not one of ContractPeriod's four states: it is
      # "active, and running out within the month", which is what the
      # dashboard sends people here to act on.
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
        client, plan, activity = sale_parties
        return if performed?

        period = Contract.sell!(
          client: client, contract_type: plan, activity: activity, created_by: current_user,
          starts_on: params[:starts_on].present? ? Date.parse(params[:starts_on]) : Date.current,
          discount: params[:discount].presence || 0,
          collect_payment: params[:collect_payment], payment_method: params[:payment_method]
        )

        AuditLog.record!(
          company: current_company, user: current_user, action: "contract.created",
          auditable: period.contract, metadata: { client: client.full_name, plan: plan.name }
        )
        render json: {
          contract: ContractSerializer.new(period.contract).as_json,
          payment: PaymentSerializer.new(period.payments.first).as_json
        }, status: :created
      end

      # PATCH /api/v1/contracts/:id — edit the current period (dates, discount)
      def update
        @contract.update_current_period!(starts_on: params[:starts_on], expires_on: params[:expires_on], discount: params[:discount])
        render json: { contract: ContractSerializer.new(@contract.reload).as_json }
      end

      # POST /api/v1/contracts/:id/renew
      def renew
        @contract.renew!
        render json: { contract: ContractSerializer.new(@contract.reload).as_json }, status: :created
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
                   filename: "recu-#{@contract.client.full_name.parameterize}-#{@contract.id.split('-').first}.pdf",
                   type: "application/pdf",
                   disposition: "attachment"
      end

      private

      # Who is buying, which plan, for which activity — each this gym's own,
      # or a 404 naming which one was not found.
      def sale_parties
        client = current_company.clients.find_by(id: params[:client_id])
        return render(json: { error: "Client not found" }, status: :not_found) if client.nil?

        plan = current_company.contract_types.active.find_by(id: params[:contract_type_id])
        return render(json: { error: "Contract plan not found" }, status: :not_found) if plan.nil?

        activity = current_company.activities.find_by(id: params[:activity_id])
        return render(json: { error: "Activity not found" }, status: :not_found) if activity.nil?

        [ client, plan, activity ]
      end

      # The list's status filter, and its counts, both look at each contract's
      # CURRENT period only — not any period in its history, and not a
      # renewal queued for later.
      def apply_status(scope, status)
        return expiring_scope(scope) if status == "expiring"

        on_current_period(scope, status)
      end

      # The "Non réglés" filter has to return exactly what its count promises,
      # so it goes through the same scope the count is built from — which
      # looks at a queued renewal's unpaid price too, not only the current
      # term's.
      def apply_payment(scope, payment)
        return unpaid_scope(scope) if payment == "unpaid"

        on_current_period(scope, :active).where(contract_periods: { payment_status: payment })
      end

      # "Running out" means the gym's COVER runs out — a contract already
      # renewed is not work, even though the term in force still ends this
      # month. Hence the second clause: nothing sold for later.
      def expiring_scope(scope)
        on_current_period(scope, :active)
          .where(contract_periods: { expires_at: Time.current..30.days.from_now })
          .where.not(id: with_a_queued_period)
      end

      # Contracts holding a period that has not started yet — a renewal
      # waiting its turn. A cancelled one sold nothing, so it does not count.
      def with_a_queued_period
        current_company.contract_periods
                       .where.not(status: :cancelled)
                       .where("COALESCE(contract_periods.starts_at, contract_periods.created_at) > :now", now: Time.current)
                       .select(:contract_id)
      end

      def on_current_period(scope, status)
        scope.joins(:contract_periods)
             .where(contract_periods: { status: status })
             .where("contract_periods.id = (#{CURRENT_PERIOD_SUBQUERY})", now: Time.current)
      end

      def searched_scope
        # preload, not includes, for the periods: every filter here joins
        # contract_periods and narrows it, and an `includes` would collapse
        # into that same join — leaving each contract holding only the rows
        # that matched the filter. Contract#current_period reads the loaded
        # association, so a filtered one would make it answer about the wrong
        # period. `preload` always fetches them in a query of its own.
        scope = current_company.contracts.for_serializer.order(created_at: :desc)
        return scope if params[:q].blank?

        t = "%#{params[:q].strip}%"
        scope.joins(:client).joins(:contract_type)
             .where("clients.first_name ILIKE :t OR clients.last_name ILIKE :t OR contract_types.name ILIKE :t", t: t)
      end

      # What the filter rail and the stats strip read. Everything here follows
      # the search term but ignores the status/plan already picked, so the
      # numbers stay comparable while the operator clicks around.
      # The four period states, plus the two the filter rail offers that are
      # not states at all: everything, and what is running out.
      def status_counts(searched)
        ContractPeriod.statuses.keys.index_with { |status| on_current_period(searched, status).distinct.count }
                      .merge(
                        "all" => searched.distinct.count,
                        "unpaid" => unpaid_scope(searched).distinct.count,
                        "expiring" => apply_status(searched, "expiring").distinct.count
                      )
      end

      def plan_counts(searched)
        searched.reorder(nil).group(:contract_type_id).distinct.count
      end

      # Owed money is owed whether it sits on the term in force or on a
      # renewal queued behind it (a renewal is sold unpaid), so this looks at
      # both rather than at the current period alone.
      def unpaid_scope(searched)
        searched.joins(:contract_periods)
                .where(contract_periods: { status: :active, payment_status: :unpaid })
                .where(<<~SQL.squish, now: Time.current)
                  (
                    contract_periods.id = (#{CURRENT_PERIOD_SUBQUERY})
                    OR COALESCE(contract_periods.starts_at, contract_periods.created_at) > :now
                  )
                SQL
      end

      # The portfolio is what the ACTIVE contracts were sold for — the frozen
      # period prices, never today's catalogue.
      def portfolio_totals(searched)
        active = on_current_period(searched, :active)
        value = active.sum("contract_periods.final_price")
        count = active.distinct.count
        {
          portfolio_value: value.to_f,
          average_basket: count.positive? ? (value.to_f / count).round(2) : 0.0,
          unpaid_value: unpaid_scope(searched).sum("contract_periods.final_price").to_f,
          expiring_soon: expiring_scope(searched).distinct.count
        }
      end

      def set_contract
        @contract = current_company.contracts.find(params[:id])
      end
    end
  end
end
