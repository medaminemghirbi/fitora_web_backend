module DataExchange
  # CSV round-trip for the activity catalogue.
  class Activities
    HEADERS = %w[name session_format duration_minutes capacity emoji description].freeze
    EXAMPLE_ROW = [ "Yoga", "collective", "60", "20", "🧘", "" ].freeze

    def self.template_csv
      CsvSafe.generate do |csv|
        csv << HEADERS
        csv << EXAMPLE_ROW
      end
    end

    def self.export_csv(company)
      CsvSafe.generate do |csv|
        csv << HEADERS
        company.activities.order(:created_at).find_each do |activity|
          csv << [ activity.name, activity.session_format, activity.duration, activity.capacity, activity.emoji, activity.description ]
        end
      end
    end

    def self.import_csv(company:, user:, io:)
      Importer.run(io) do |row|
        activity = company.activities.new(
          name: row["name"].to_s.strip,
          session_format: row["session_format"].to_s.strip,
          duration: row["duration_minutes"],
          capacity: row["capacity"],
          emoji: row["emoji"].to_s.strip.presence,
          description: row["description"].to_s.strip.presence
        )
        activity.errors.full_messages.join(", ") unless activity.save
      end
    end
  end
end
