class SuperadminSupportTicketSerializer
  def initialize(ticket)
    @ticket = ticket
  end

  def as_json(*)
    {
      id: ticket.id,
      subject: ticket.subject,
      message: ticket.message,
      status: ticket.status,
      kind: ticket.kind,
      contact_phone: ticket.contact_phone,
      created_at: ticket.created_at,
      company: { id: ticket.company.id, name: ticket.company.name },
      created_by: { id: ticket.created_by.id, full_name: ticket.created_by.full_name, email: EmailMask.call(ticket.created_by.email) },
      attachments: attachments_json
    }
  end

  private

  attr_reader :ticket

  def attachments_json
    ticket.attachments.map do |file|
      {
        id: file.id,
        filename: file.filename.to_s,
        content_type: file.content_type,
        byte_size: file.byte_size,
        url: Rails.application.routes.url_helpers.attachment_api_v1_superadmin_support_ticket_path(ticket, attachment_id: file.id)
      }
    end
  end
end
