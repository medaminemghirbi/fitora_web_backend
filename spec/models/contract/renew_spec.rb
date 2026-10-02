require "rails_helper"

RSpec.describe Contract, "#renew!" do
  it "queues a new period behind the running one, and leaves the running one alone" do
    plan = create(:contract_type)
    client = create(:client, company: plan.company)
    original = create(:contract, client: client, contract_type: plan, company: plan.company,
                                    starts_at: 30.days.ago, expires_at: 5.days.from_now)
    original_period = original.current_period

    renewal = original.renew!

    expect(renewal.contract_id).to eq(original.id)
    original.reload
    expect(original.contract_periods.count).to eq(2)

    # The term still running stays the current one, untouched — renewing
    # early buys the NEXT term, it does not rewrite the one being lived.
    expect(original.current_period.id).to eq(original_period.id)
    expect(original.expires_at.to_date).to eq(original_period.expires_at.to_date)
    expect(original_period.reload.status).to eq("active")

    queued = original.next_period
    expect(queued.id).to eq(renewal.id)
    expect(queued.starts_at.to_date).to eq(original_period.expires_at.to_date)
    expect(queued.expires_at.to_date).to eq(original_period.expires_at.to_date + 30.days)
  end

  it "stacks a second renewal behind the first instead of overlapping it" do
    plan = create(:contract_type)
    client = create(:client, company: plan.company)
    contract = create(:contract, client: client, contract_type: plan, company: plan.company,
                                 starts_at: 30.days.ago, expires_at: 5.days.from_now)
    running = contract.current_period

    contract.renew!
    contract.reload.renew!

    contract.reload
    expect(contract.contract_periods.count).to eq(3)
    expect(contract.current_period.id).to eq(running.id)
    first, second = contract.upcoming_periods
    expect(first.starts_at.to_date).to eq(running.expires_at.to_date)
    expect(second.starts_at.to_date).to eq(first.expires_at.to_date)
  end

  it "starts the new period today when the current one has already expired" do
    plan = create(:contract_type)
    client = create(:client, company: plan.company)
    original = create(:contract, client: client, contract_type: plan, company: plan.company,
                                    starts_at: 40.days.ago, expires_at: 10.days.ago, status: :expired)

    original.renew!

    expect(original.reload.starts_at.to_date).to eq(Date.current)
  end

  it "renews at today's tariff, leaving the previous period at what it was sold for" do
    activity = create(:activity)
    plan = create(:contract_type, company: activity.company, activity: activity, price: 70)
    client = create(:client, company: plan.company)
    contract = create(:contract, client: client, contract_type: plan, company: plan.company, activity: activity)
    first_period = contract.current_period

    plan.contract_type_activities.find_by(activity: activity).update!(price: 80)
    renewal = contract.renew!

    expect(first_period.reload.final_price).to eq(70)
    expect(renewal.final_price).to eq(80)
  end

  it "falls back to the previous period's price when the plan no longer prices that activity" do
    activity = create(:activity)
    plan = create(:contract_type, company: activity.company, activity: activity, price: 70)
    client = create(:client, company: plan.company)
    contract = create(:contract, client: client, contract_type: plan, company: plan.company, activity: activity)

    plan.contract_type_activities.find_by(activity: activity).destroy
    expect(contract.renew!.final_price).to eq(70)
  end
end
