require "rails_helper"

RSpec.describe Contract, "#renew!" do
  it "sells a new contract queued behind the running one, and leaves the running one alone" do
    plan = create(:contract_type)
    client = create(:client, company: plan.company)
    original = create(:contract, client: client, contract_type: plan, company: plan.company,
                                    starts_at: 30.days.ago, expires_at: 5.days.from_now)

    renewal = original.renew!

    expect(renewal).not_to eq(original)
    expect(renewal.renewed_from).to eq(original)
    expect(renewal.client).to eq(client)
    expect(renewal.contract_type).to eq(plan)

    # The term still running is untouched — renewing early buys the NEXT
    # term, it does not rewrite the one being lived.
    original.reload
    expect(original.expires_at.to_date).to eq(5.days.from_now.to_date)
    expect(original.status).to eq("active")

    expect(renewal.starts_at.to_date).to eq(original.expires_at.to_date)
    expect(renewal.expires_at.to_date).to eq(original.expires_at.to_date + 30.days)
  end

  it "renews only the latest term — the one already renewed refuses" do
    plan = create(:contract_type)
    running = create(:contract, contract_type: plan, starts_at: 25.days.ago, expires_at: 5.days.from_now)
    queued = running.renew!

    expect(running).not_to be_renewable
    expect { running.renew! }.to raise_error(ApplicationRecord::Refused, /already been renewed/)
    # The renewal itself waits for its own window: it ends a month after that.
    expect(queued).not_to be_renewable
  end

  it "refuses more than #{Contract::RENEWAL_WINDOW.in_days.to_i} days before the term ends" do
    contract = create(:contract, starts_at: 5.days.ago, expires_at: 25.days.from_now)

    expect(contract).not_to be_renewable
    expect { contract.renew! }.to raise_error(ApplicationRecord::Refused, /10 days before it ends/)
  end

  it "opens #{Contract::RENEWAL_WINDOW.in_days.to_i} days before the end" do
    contract = create(:contract, starts_at: 20.days.ago, expires_at: 9.days.from_now)

    expect(contract).to be_renewable
  end

  it "renews a carnet whose sessions are spent at once, starting today rather than at its end date" do
    plan = create(:contract_type, unlimited_bookings: false, booking_limit: 10)
    carnet = create(:contract, contract_type: plan, remaining_bookings: 0, starts_at: 10.days.ago, expires_at: 40.days.from_now)

    expect(carnet).to be_renewable
    renewal = carnet.renew!
    expect(renewal.starts_at.to_date).to eq(Date.current)
    expect(renewal.remaining_bookings).to eq(10)
  end

  it "starts the new contract today when the current one has already expired" do
    plan = create(:contract_type)
    client = create(:client, company: plan.company)
    original = create(:contract, client: client, contract_type: plan, company: plan.company,
                                    starts_at: 40.days.ago, expires_at: 10.days.ago, status: :expired)

    expect(original.renew!.starts_at.to_date).to eq(Date.current)
  end

  it "refuses a cancelled term — coming back after a cancellation is a new sale" do
    original = create(:contract, starts_at: 5.days.ago, expires_at: 5.days.from_now, status: :cancelled)

    expect(original).not_to be_renewable
    expect { original.renew! }.to raise_error(ApplicationRecord::Refused, /active or expired/)
  end

  it "renews at today's tariff, leaving the previous contract at what it was sold for" do
    activity = create(:activity)
    plan = create(:contract_type, company: activity.company, activity: activity, price: 70)
    client = create(:client, company: plan.company)
    contract = create(:contract, client: client, contract_type: plan, company: plan.company, activity: activity,
                                 expires_at: 5.days.from_now)

    plan.contract_type_activities.find_by(activity: activity).update!(price: 80)
    renewal = contract.renew!

    expect(contract.reload.final_price).to eq(70)
    expect(renewal.final_price).to eq(80)
  end

  it "falls back to the previous contract's price when the plan no longer prices that activity" do
    activity = create(:activity)
    plan = create(:contract_type, company: activity.company, activity: activity, price: 70)
    client = create(:client, company: plan.company)
    contract = create(:contract, client: client, contract_type: plan, company: plan.company, activity: activity,
                                 expires_at: 5.days.from_now)

    plan.contract_type_activities.find_by(activity: activity).destroy
    expect(contract.renew!.final_price).to eq(70)
  end

  describe "onto another formule" do
    let(:activity) { create(:activity) }
    let(:monthly) { create(:contract_type, company: activity.company, activity: activity, price: 70) }
    let(:yearly) { create(:contract_type, company: activity.company, activity: activity, price: 700, billing_period: :yearly) }
    let(:contract) do
      create(:contract, contract_type: monthly, activity: activity, discount: 10,
                        starts_at: 25.days.ago, expires_at: 5.days.from_now)
    end

    it "sells the new formule at its own price and length, still chained to the old term" do
      renewal = contract.renew!(contract_type: yearly)

      expect(renewal.contract_type).to eq(yearly)
      expect(renewal.renewed_from).to eq(contract)
      expect(renewal.base_price).to eq(700)
      expect(renewal.expires_at.to_date).to eq(renewal.starts_at.to_date + 365.days)
    end

    it "leaves the old formule's discount behind" do
      expect(contract.renew!(contract_type: yearly).discount).to eq(0)
    end

    it "refuses a formule with no price for the activity" do
      unpriced = create(:contract_type, company: activity.company)

      expect { contract.renew!(contract_type: unpriced) }.to raise_error(ApplicationRecord::Refused, /no price/)
    end
  end
end
