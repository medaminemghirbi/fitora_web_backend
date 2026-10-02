module DataExchange
  # CSV round-trip for the client roster — the most common migration path
  # for a gym coming from another system (spreadsheet or a competitor export).
  class Clients
    HEADERS = %w[first_name last_name email phone].freeze
    EXAMPLE_ROW = [ "Amine", "Test", "amine@example.com", "+21620000000" ].freeze

    def self.template_csv
      CsvSafe.generate do |csv|
        csv << HEADERS
        csv << EXAMPLE_ROW
      end
    end

    def self.export_csv(company)
      CsvSafe.generate do |csv|
        csv << HEADERS
        company.clients.order(:created_at).find_each do |client|
          csv << [ client.first_name, client.last_name, client.email, client.phone ]
        end
      end
    end

    # An email that already has an account joins that person to this gym
    # rather than failing on the platform-wide uniqueness — importing a
    # member list must not depend on whether they train elsewhere too.
    def self.import_csv(company:, user:, io:)
      Importer.run(io) do |row|
        email = row["email"].to_s.strip
        client = Client.find_by_email(email) || Client.new(email: email.presence)
        if client.new_record?
          client.assign_attributes(
            first_name: row["first_name"].to_s.strip,
            last_name: row["last_name"].to_s.strip,
            phone: row["phone"].to_s.strip
          )
        end

        ActiveRecord::Base.transaction do
          client.save!
          client.join!(company)
        end
        nil
      rescue ActiveRecord::RecordInvalid => e
        e.record.errors.full_messages.join(", ")
      end
    end
  end
end
