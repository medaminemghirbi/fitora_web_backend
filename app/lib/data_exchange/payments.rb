module DataExchange
  # CSV import for payments. A Payment can never stand alone (see
  # Payment#linked_to_exactly_one_payable) — an imported row is recorded
  # against the client's current contract period, the same target the
  # "Encaisser" action on a contract would use.
  class Payments
    HEADERS = %w[client_email amount payment_method paid_at].freeze
    EXAMPLE_ROW = [ "amine@example.com", "90", "cash", Date.current.to_s ].freeze

    def self.template_csv
      CsvSafe.generate do |csv|
        csv << HEADERS
        csv << EXAMPLE_ROW
      end
    end

    def self.export_csv(company)
      CsvSafe.generate do |csv|
        csv << HEADERS
        company.payments.includes(:client).order(:created_at).find_each do |payment|
          csv << [ payment.client.email, payment.amount, payment.payment_method, payment.paid_at&.to_date ]
        end
      end
    end

    def self.import_csv(company:, user:, io:)
      Importer.run(io) { |row| import_row(company, user, row) }
    end

    # nil when the payment was recorded, otherwise why not.
    def self.import_row(company, user, row)
      email = row["client_email"].to_s.strip.downcase
      client = company.clients.find_by(email: email)
      return "No client found with email #{email}" unless client

      # This gym's contract: the same person may be subscribed elsewhere too.
      contract = client.current_contract(company)
      return "#{email} has no active contract to record a payment against" unless contract

      method = row["payment_method"].to_s.strip.presence || "cash"
      unless ::Payment::SELECTABLE_METHODS.include?(method)
        return "Invalid payment method: #{method} (use cash, bank_transfer or other)"
      end

      ::Payment.collect!(
        client: client, company: company, created_by: user,
        amount: row["amount"], payment_method: method, contract: contract
      )
      nil
    rescue ::ApplicationRecord::Refused => e
      e.message
    rescue ActiveRecord::RecordInvalid => e
      e.record.errors.full_messages.first
    end
    private_class_method :import_row
  end
end
