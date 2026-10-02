require "csv"

# CSV that a spreadsheet opens as data, not as formulas.
#
# Excel and LibreOffice run a cell starting with =, +, -, @, a tab or a
# carriage return as a formula. A member's name is typed by whoever created
# them, so "=HYPERLINK(…)" in a name would run on the admin's machine the
# moment they opened an export. Such cells get a leading apostrophe, which
# spreadsheets read as "this is text".
#
# Phone numbers and negative amounts are left alone: "+216 20 111 111" and
# "-12.5" start with a sign but are only digits after it.
module CsvSafe
  DANGEROUS = /\A[=@\t\r]|\A[+-](?![\d\s().]*\z)/

  def self.cell(value)
    return value unless value.is_a?(String) && value.match?(DANGEROUS)

    "'#{value}"
  end

  # Drop-in for CSV.generate: every row appended is escaped on the way in.
  def self.generate(**options)
    CSV.generate(**options) { |csv| yield Writer.new(csv) }
  end

  class Writer
    def initialize(csv)
      @csv = csv
    end

    def <<(row)
      @csv << row.map { |value| CsvSafe.cell(value) }
      self
    end
  end
end
