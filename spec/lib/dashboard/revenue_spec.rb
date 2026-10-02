require "rails_helper"

RSpec.describe Dashboard::Revenue do
  def paid_payment(company, amount:, paid_at:)
    client = create(:client, company: company)
    plan = create(:contract_type, company: company)
    contract = create(:contract, client: client, contract_type: plan)

    create(:payment, company: company, client: client, contract_period: contract.current_period,
                      amount: amount, paid_at: paid_at, status: :paid)
  end

  it "buckets paid revenue into today, this week, this month, and a 14-day daily breakdown" do
    travel_to Time.zone.local(2025, 6, 18, 12, 0, 0) do
      company = create(:company)

      paid_payment(company, amount: 50, paid_at: Time.zone.local(2025, 6, 18, 10, 0, 0)) # today
      paid_payment(company, amount: 30, paid_at: Time.zone.local(2025, 6, 16, 10, 0, 0)) # this week, not today
      paid_payment(company, amount: 20, paid_at: Time.zone.local(2025, 6, 2, 10, 0, 0))  # this month, not this week
      paid_payment(company, amount: 999, paid_at: Time.zone.local(2025, 5, 1, 10, 0, 0)) # outside the month entirely

      result = described_class.call(company: company)

      expect(result[:today]).to eq(50)
      expect(result[:this_week]).to eq(80)
      expect(result[:this_month]).to eq(100)

      by_day_dates = result[:by_day].map { |d| d[:date].to_s }
      expect(by_day_dates).to include("2025-06-16", "2025-06-18")
      expect(by_day_dates).not_to include("2025-06-02", "2025-05-01")

      entry_for_16th = result[:by_day].find { |d| d[:date].to_s == "2025-06-16" }
      expect(entry_for_16th[:total]).to eq(30)
    end
  end

  describe ".by_month" do
    it "returns twelve months ending with this one, oldest first" do
      travel_to Time.zone.local(2025, 6, 18, 12, 0, 0) do
        months = described_class.by_month(company: create(:company)).map { |m| m[:month].to_s }

        expect(months.length).to eq(12)
        expect(months.first).to eq("2024-07-01")
        expect(months.last).to eq("2025-06-01")
      end
    end

    # A gap in a line chart reads as missing data, not as a month where the
    # gym took nothing. Every month is present, zero or not.
    it "carries a zero for a month with no takings rather than leaving it out" do
      travel_to Time.zone.local(2025, 6, 18, 12, 0, 0) do
        company = create(:company)
        paid_payment(company, amount: 120, paid_at: Time.zone.local(2025, 4, 9, 10, 0, 0))

        by_month = described_class.by_month(company: company)

        expect(by_month.find { |m| m[:month].to_s == "2025-04-01" }[:total]).to eq(120)
        expect(by_month.find { |m| m[:month].to_s == "2025-05-01" }[:total]).to eq(0)
        expect(by_month.map { |m| m[:total] }.sum).to eq(120)
      end
    end

    it "sums every payment inside one month" do
      travel_to Time.zone.local(2025, 6, 18, 12, 0, 0) do
        company = create(:company)
        paid_payment(company, amount: 40, paid_at: Time.zone.local(2025, 6, 2, 10, 0, 0))
        paid_payment(company, amount: 60, paid_at: Time.zone.local(2025, 6, 17, 10, 0, 0))

        expect(described_class.by_month(company: company).last).to include(total: 100)
      end
    end

    it "leaves another company's takings out" do
      travel_to Time.zone.local(2025, 6, 18, 12, 0, 0) do
        company = create(:company)
        paid_payment(create(:company), amount: 500, paid_at: Time.current)

        expect(described_class.by_month(company: company).map { |m| m[:total] }.sum).to eq(0)
      end
    end
  end

  it "only counts payments belonging to the given company" do
    travel_to Time.zone.local(2025, 6, 18, 12, 0, 0) do
      company = create(:company)
      other_company = create(:company)
      paid_payment(company, amount: 40, paid_at: Time.current)
      paid_payment(other_company, amount: 500, paid_at: Time.current)

      result = described_class.call(company: company)

      expect(result[:today]).to eq(40)
    end
  end

  it "returns zero totals and an empty daily breakdown for a company with no paid revenue" do
    company = create(:company)

    result = described_class.call(company: company)

    expect(result[:today]).to eq(0)
    expect(result[:this_week]).to eq(0)
    expect(result[:this_month]).to eq(0)
    expect(result[:by_day]).to eq([])
  end
end
