module Api
  module V1
    class PaymentsController < BaseController
      before_action :require_company!
      before_action -> { require_capability!(:payments) }
      # Money going back out is the admin's call, not the desk's.
      before_action :require_admin!, only: :refund
      before_action :set_payment, only: [ :show, :refund ]

      # GET /api/v1/payments?status=&payment_method=&date=
      def index
        searched = searched_scope
        scope = searched
        scope = scope.where(status: params[:status]) if params[:status].present?
        scope = scope.where(payment_method: params[:payment_method]) if params[:payment_method].present?
        scope = scope.where("created_at >= ?", Date.parse(params[:date]).beginning_of_day) if params[:date].present?
        scope = scope.recent

        if params[:format] == "csv"
          return render_forbidden unless current_user.admin?

          send_data payments_csv(scope), filename: "payments-#{Date.current}.csv"
        else
          render json: {
            payments: paginate(scope).map { |p| PaymentSerializer.new(p).as_json },
            meta: pagination_meta(scope),
            counts: status_counts(searched),
            method_counts: searched.group(:payment_method).count,
            # Taking money at the desk is `payments`; reading what the gym
            # has taken in is `revenue`. Without it the strip is simply absent.
            **(capability?(:revenue) ? { totals: cash_totals(searched) } : {})
          }
        end
      end

      # What the filter rail and the stats strip read, all on the searched set
      # so the numbers follow the search box and not the status picked.
      def searched_scope
        scope = current_company.payments.includes(:client, :company, :created_by)
                                 .preload(contract: :contract_type, booking: { session: :activity })
        return scope if params[:q].blank?

        t = "%#{params[:q].strip}%"
        scope.joins(:client).where("clients.first_name ILIKE :t OR clients.last_name ILIKE :t", t: t)
      end

      def status_counts(searched)
        searched.group(:status).count.merge("all" => searched.count)
      end

      def cash_totals(searched)
        paid = searched.where(status: :paid)
        {
          collected_this_month: paid.where(paid_at: Time.current.beginning_of_month..).sum(:amount).to_f,
          collected_total: paid.sum(:amount).to_f,
          refunded_value: searched.where(status: :refunded).sum(:amount).to_f,
          cancelled_value: searched.where(status: :cancelled).sum(:amount).to_f,
          average_payment: paid.count.positive? ? (paid.sum(:amount).to_f / paid.count).round(2) : 0.0
        }
      end

      # GET /api/v1/payments/:id
      def show
        render json: { payment: PaymentSerializer.new(@payment).as_json }
      end

      # POST /api/v1/payments — staff manually records a payment against a
      # client's contract or booking
      def create
        client = current_company.clients.find_by(id: params[:client_id])
        return render json: { error: "Client not found" }, status: :not_found if client.nil?

        payment = Payment.collect!(
          client: client, company: current_company, created_by: current_user,
          amount: params[:amount], payment_method: params[:payment_method], notes: params[:notes],
          # This gym's only: the person may owe other gyms too.
          contract: find_payable(current_company.contracts.where(client_id: client.id), params[:contract_id]),
          booking: find_payable(client.bookings_for(current_company), params[:booking_id])
        )

        AuditLog.record!(
          company: current_company, user: current_user, action: "payment.recorded",
          auditable: payment, metadata: { client: client.full_name, amount: payment.amount, method: payment.payment_method }
        )
        render json: { payment: PaymentSerializer.new(payment).as_json }, status: :created
      end

      # POST /api/v1/payments/:id/refund
      def refund
        @payment.refund!
        AuditLog.record!(
          company: current_company, user: current_user, action: "payment.refunded",
          auditable: @payment, metadata: { client: @payment.client.full_name, amount: @payment.amount }
        )
        render json: { payment: PaymentSerializer.new(@payment.reload).as_json }
      end

      private

      def find_payable(scope, id)
        return nil if id.blank?

        scope.find_by(id: id)
      end

      def set_payment
        @payment = current_company.payments.find_by(id: params[:id])
        render_not_found if @payment.nil?
      end

      def payments_csv(scope)
        CsvSafe.generate do |csv|
          csv << [ "Client", "Amount", "Currency", "Method", "Status", "Paid at" ]
          scope.includes(:client).find_each do |p|
            csv << [ p.client.full_name, p.amount, p.currency, p.payment_method, p.status, p.paid_at ]
          end
        end
      end
    end
  end
end
