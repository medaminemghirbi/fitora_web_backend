require "rails_helper"

RSpec.describe Subscription, ".close_unpaid!" do
  def gym(period_end:, active: true)
    company = create(:company)
    subscription = create(:subscription, company: company, active: active)
    create(:invoice, company: company, period_start: period_end - 30, period_end: period_end) if period_end
    [ company, subscription ]
  end

  it "closes a gym whose paid period ran out more than three days ago" do
    _company, subscription = gym(period_end: Date.current - 4)

    expect(described_class.close_unpaid!).to eq(1)
    expect(subscription.reload).not_to be_active
  end

  it "leaves one still inside its three days alone" do
    _company, subscription = gym(period_end: Date.current - 3)

    expect(described_class.close_unpaid!).to eq(0)
    expect(subscription.reload).to be_active
  end

  it "leaves a paid-up gym alone" do
    _company, subscription = gym(period_end: Date.current.end_of_month)

    described_class.close_unpaid!
    expect(subscription.reload).to be_active
  end

  it "closes a trial the day after its free days end, with no grace" do
    company = create(:company)
    subscription = create(:subscription, company: company)
    create(:invoice, :trial, company: company, period_start: Date.current - 14, period_end: Date.current.prev_day)

    expect(described_class.close_unpaid!).to eq(1)
    expect(subscription.reload).not_to be_active
  end

  it "leaves a trial alone on its last free day" do
    company = create(:company)
    subscription = create(:subscription, company: company)
    create(:invoice, :trial, company: company, period_start: Date.current - 13, period_end: Date.current)

    described_class.close_unpaid!
    expect(subscription.reload).to be_active
  end

  it "closes a gym that never had an invoice at all" do
    _company, subscription = gym(period_end: nil)

    expect(described_class.close_unpaid!).to eq(1)
    expect(subscription.reload).not_to be_active
  end

  # It only ever moves active from true to false, so a missed night caught up
  # late, or two runs in a row, land in the same place.
  it "is idempotent" do
    gym(period_end: Date.current - 10)

    expect(described_class.close_unpaid!).to eq(1)
    expect(described_class.close_unpaid!).to eq(0)
  end

  it "never reopens a gym a superadmin suspended" do
    _company, subscription = gym(period_end: Date.current.end_of_month, active: false)

    described_class.close_unpaid!
    expect(subscription.reload).not_to be_active
  end
end
