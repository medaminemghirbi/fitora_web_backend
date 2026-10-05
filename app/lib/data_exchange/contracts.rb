module DataExchange
  # CSV import for contracts — deliberately thin: it just resolves the
  # client (by email) and membership plan (by name) already in the company,
  # then hands off to Contract.sell! so pricing/dates/payment status
  # stay computed the exact same way a manual "new contract" does.
  class Contracts
    HEADERS = %w[client_email contract_type_name activity_name starts_at].freeze
    EXAMPLE_ROW = [ "amine@example.com", "Abonnement mensuel", "Yoga", Date.current.to_s ].freeze

    def self.template_csv
      CsvSafe.generate do |csv|
        csv << HEADERS
        csv << EXAMPLE_ROW
      end
    end

    def self.export_csv(company)
      CsvSafe.generate do |csv|
        csv << HEADERS
        company.contracts.includes(:client, :contract_type, :activity).order(:created_at).find_each do |contract|
          csv << [ contract.client.email, contract.contract_type.name, contract.activity_label, contract.starts_at&.to_date ]
        end
      end
    end

    def self.import_csv(company:, user:, io:)
      Importer.run(io) { |row| import_row(company, user, row) }
    end

    # nil when the contract was created, otherwise why not.
    def self.import_row(company, user, row)
      email = row["client_email"].to_s.strip.downcase
      client = company.clients.find_by(email: email)
      return "No client found with email #{email}" unless client

      type_name = row["contract_type_name"].to_s.strip
      contract_type = company.contract_types.find_by(name: type_name)
      return "No membership plan named \"#{type_name}\"" unless contract_type

      activity_name = row["activity_name"].to_s.strip
      activity = company.activities.find_by(name: activity_name)
      return "No activity named \"#{activity_name}\"" unless activity

      starts_on = parse_date(row["starts_at"])
      return "Invalid date: #{row['starts_at']}" if starts_on == :invalid

      ::Contract.sell!(client: client, contract_type: contract_type, activity: activity,
                       created_by: user, starts_on: starts_on || Date.current)
      nil
    rescue ::ApplicationRecord::Refused => e
      e.message
    rescue ActiveRecord::RecordInvalid => e
      e.record.errors.full_messages.first
    end
    private_class_method :import_row

    def self.parse_date(value)
      return nil if value.blank?

      Date.parse(value)
    rescue ArgumentError, TypeError
      :invalid
    end
    private_class_method :parse_date
  end
end
