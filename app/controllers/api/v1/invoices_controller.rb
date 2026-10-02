module Api
  module V1
    # The account's own invoices: the record that it paid, and the PDF it
    # keeps. One set for every salle the admin runs.
    class InvoicesController < BaseController
      before_action :require_company!
      before_action :require_admin!
      before_action :set_invoice, only: [ :show ]

      # GET /api/v1/invoices
      def index
        render json: {
          invoices: account_invoices.newest_first.map { |i| InvoiceSerializer.new(i).as_json }
        }
      end

      # GET /api/v1/invoices/:id — the PDF.
      def show
        pdf = Receipts::SubscriptionInvoicePdf.call(invoice: @invoice)

        send_data pdf,
                  filename: "#{@invoice.number}.pdf",
                  type: "application/pdf",
                  disposition: "attachment"
      end

      private

      def set_invoice
        @invoice = account_invoices.find(params[:id])
      end

      def account_invoices
        current_company.subscription&.invoices || Invoice.none
      end
    end
  end
end
