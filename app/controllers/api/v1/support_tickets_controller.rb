module Api
  module V1
    # The "Contact" tab on the modules marketplace page — a problem report
    # with optional file/video attachments, reviewed by a Fitora superadmin from
    # a cross-company inbox (Api::V1::Superadmin::SupportTicketsController).
    class SupportTicketsController < BaseController
      before_action :require_admin!
      before_action :set_ticket, only: [ :attachment ]

      # GET /api/v1/support_tickets
      def index
        tickets = current_company.support_tickets.recent
        render json: { support_tickets: tickets.map { |t| SupportTicketSerializer.new(t).as_json } }
      end

      # POST /api/v1/support_tickets (multipart/form-data — attachments[] are uploads)
      #
      # kind=upgrade marks a plan request from the subscription page, which
      # must carry a contact_phone (see SupportTicket).
      def create
        ticket = current_company.support_tickets.new(
          subject: params[:subject], message: params[:message], created_by: current_user,
          kind: SupportTicket.kinds.key?(params[:kind].to_s) ? params[:kind] : :general,
          contact_phone: params[:contact_phone]
        )
        ticket.attachments.attach(params[:attachments]) if params[:attachments].present?

        if ticket.save
          AuditLog.record!(
            company: current_company, user: current_user, action: "support_ticket.created",
            auditable: ticket, metadata: { subject: ticket.subject, kind: ticket.kind }
          )
          render json: { support_ticket: SupportTicketSerializer.new(ticket).as_json }, status: :created
        else
          render_errors(ticket)
        end
      end

      # GET /api/v1/support_tickets/:id/attachments/:attachment_id — streamed
      # rather than a public Active Storage URL, so access still goes through
      # the tenant/permission check above instead of a guessable public link.
      def attachment
        file = @ticket.attachments.find(params[:attachment_id])
        send_data file.download, filename: file.filename.to_s, type: file.content_type, disposition: "inline"
      end

      private

      def set_ticket
        @ticket = current_company.support_tickets.find(params[:id])
      end
    end
  end
end
