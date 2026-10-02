require "rails_helper"

# The second line under an attention row. "4 impayés" is a number; "le plus
# ancien remonte à 23 jours" is a reason to deal with it today.
RSpec.describe Dashboard::Statistics, "attention details" do
  let(:company) { create(:company) }
  let(:plan) { create(:contract_type, company: company) }

  def row(key, revenue: true)
    described_class.new(company: company, revenue: revenue).call[:attention].find { |r| r[:key] == key }
  end

  def contract_with(period_attrs)
    contract = create(:contract, company: company, client: create(:client, company: company), contract_type: plan)
    contract.current_period.update!(period_attrs)
    contract
  end

  describe "expiring" do
    it "says how many run out today" do
      # Always today, whatever o'clock the suite runs at: `2.hours.from_now`
      # stops meaning today once it runs after 22:00, which is how this first
      # failed.
      contract_with(status: :active, expires_at: Time.current.end_of_day - 1.minute)
      contract_with(status: :active, expires_at: 10.days.from_now)

      expect(row("expiring")[:detail]).to eq({ kind: "expiring_today", count: 1 })
    end

    it "has no detail when none run out today" do
      contract_with(status: :active, expires_at: 10.days.from_now)

      expect(row("expiring")[:detail]).to be_nil
    end
  end

  describe "unpaid" do
    it "says how old the oldest one is" do
      contract_with(status: :active, payment_status: :unpaid, starts_at: 23.days.ago, expires_at: 7.days.from_now)

      expect(row("unpaid")[:detail]).to eq({ kind: "oldest_days", count: 23 })
    end

    it "has no detail for one that started today — nothing is overdue yet" do
      contract_with(status: :active, payment_status: :unpaid, starts_at: 2.hours.ago, expires_at: 30.days.from_now)

      expect(row("unpaid")[:detail]).to be_nil
    end
  end

  describe "expired" do
    it "says how long ago the oldest one ran out" do
      contract_with(status: :active, starts_at: 60.days.ago, expires_at: 9.days.ago)

      expect(row("expired")[:detail]).to eq({ kind: "oldest_days", count: 9 })
    end
  end

  it "never gives the coachless-sessions row a detail — the count is the whole story" do
    expect(row("sessions_without_coach")).to have_key(:detail)
    expect(row("sessions_without_coach")[:detail]).to be_nil
  end

  it "keeps the detail out of a login that may not read money, along with the amount" do
    contract_with(status: :active, payment_status: :unpaid, starts_at: 23.days.ago, expires_at: 7.days.from_now)

    unpaid = row("unpaid", revenue: false)

    expect(unpaid[:amount]).to be_nil
    # The age is not a money figure, so it stays: knowing something is 23 days
    # overdue is operational, not financial.
    expect(unpaid[:detail]).to eq({ kind: "oldest_days", count: 23 })
  end
end
