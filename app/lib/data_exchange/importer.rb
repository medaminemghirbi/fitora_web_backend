module DataExchange
  # The loop every CSV import shares. Each row is handed to the block, which
  # returns nil when it created something and the reason when it did not;
  # a refused row is reported with its line in the file (the header is line
  # 1) and the rest carry on.
  module Importer
    def self.run(io)
      created = 0
      errors = []

      CSV.parse(io.read, headers: true).each_with_index do |row, index|
        message = yield(row)
        if message.nil?
          created += 1
        else
          errors << { row: index + 2, message: message }
        end
      end

      { created: created, errors: errors }
    end
  end
end
