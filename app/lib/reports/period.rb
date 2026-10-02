module Reports
  # Parses the "month" or "year" period the admin picked in the export
  # dialog into a concrete time range, plus a human label and a filename
  # slug — used by Reports::CompanyWorkbook to scope revenue figures.
  class Period
    class InvalidPeriod < StandardError; end

    MONTH_NAMES_FR = %w[
      janvier février mars avril mai juin juillet août septembre octobre novembre décembre
    ].freeze

    def self.parse(period_type:, period:)
      case period_type
      when "year"
        year = Integer(period, 10)
        raise InvalidPeriod, "year out of range" unless year.between?(2000, 2100)

        range = Time.zone.local(year, 1, 1)..Time.zone.local(year, 12, 31, 23, 59, 59)
        new(kind: "year", range: range, label: year.to_s, slug: year.to_s)
      when "month"
        year, month = period.to_s.split("-").map { |p| Integer(p, 10) }
        raise InvalidPeriod, "month out of range" unless month.between?(1, 12)

        start = Time.zone.local(year, month, 1)
        range = start.beginning_of_month..start.end_of_month
        new(kind: "month", range: range, label: "#{MONTH_NAMES_FR[month - 1]} #{year}", slug: format("%04d-%02d", year, month))
      else
        raise InvalidPeriod, "unknown period_type #{period_type.inspect}"
      end
    rescue ArgumentError, TypeError
      raise InvalidPeriod, "could not parse period #{period.inspect}"
    end

    attr_reader :kind, :range, :label, :slug

    def initialize(kind:, range:, label:, slug:)
      @kind = kind
      @range = range
      @label = label
      @slug = slug
    end
  end
end
