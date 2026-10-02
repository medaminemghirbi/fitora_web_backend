module Dashboard
  class Revenue
    # Twelve months ending with this one, every month present even when
    # nothing came in — a gap in a line chart reads as missing data, not as
    # a month where the gym took nothing.
    MONTHS_BACK = 11

    def self.call(company:)
      new(company: company).call
    end

    def self.by_month(company:)
      new(company: company).by_month
    end

    def initialize(company:)
      @company = company
    end

    def call
      {
        today: paid_scope.where(paid_at: Time.current.all_day).sum(:amount),
        this_week: paid_scope.where(paid_at: Time.current.all_week).sum(:amount),
        this_month: paid_scope.where(paid_at: Time.current.all_month).sum(:amount),
        by_day: grouped_by_day,
        by_month: by_month
      }
    end

    def by_month
      first = MONTHS_BACK.months.ago.beginning_of_month
      totals = paid_scope.where(paid_at: first..Time.current)
                         .group("DATE_TRUNC('month', paid_at)")
                         .sum(:amount)
                         .transform_keys { |t| t.to_date.beginning_of_month }

      (0..MONTHS_BACK).map do |offset|
        month = (first + offset.months).to_date
        { month: month, total: totals.fetch(month, 0) }
      end
    end

    private

    attr_reader :company

    def paid_scope
      company.payments.paid
    end

    def grouped_by_day
      paid_scope.where(paid_at: 13.days.ago.beginning_of_day..Time.current)
                .group("DATE(paid_at)")
                .order("DATE(paid_at)")
                .sum(:amount)
                .map { |date, total| { date: date, total: total } }
    end
  end
end
