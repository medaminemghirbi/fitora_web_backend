require "rails_helper"

RSpec.describe Contract, ".sell!" do
  it "creates an active contract with expires_at derived from the plan's duration" do
    activity = create(:activity)
    plan = create(:contract_type, company: activity.company, activity: activity, price: 89)
    client = create(:client, company: plan.company)
    staff = create(:user, :admin)

    starts_on = Date.current
    period = Contract.sell!(client: client, contract_type: plan, activity: activity, created_by: staff, starts_on: starts_on)

    expect(period.contract).to be_active
    expect(period.contract.activity).to eq(activity)
    expect(period.contract.expires_at.to_date).to eq(starts_on + 30.days)
    expect(period.contract.final_price).to eq(89)
  end

  it "applies a discount to the final price" do
    activity = create(:activity)
    plan = create(:contract_type, company: activity.company, activity: activity, price: 100)
    client = create(:client, company: plan.company)
    staff = create(:user, :admin)

    period = Contract.sell!(client: client, contract_type: plan, activity: activity, created_by: staff, discount: 20)

    expect(period.contract.final_price).to eq(80)
  end

  it "records a full-price payment and marks the abonnement paid when collect_payment is set" do
    activity = create(:activity)
    plan = create(:contract_type, company: activity.company, activity: activity, price: 89)
    client = create(:client, company: plan.company)
    staff = create(:user, :admin)

    period = Contract.sell!(client: client, contract_type: plan, activity: activity, created_by: staff, collect_payment: true, payment_method: "bank_transfer")

    expect(period.payments.first).to be_paid
    expect(period.payments.first.amount).to eq(89)
    expect(period.contract).to be_paid
  end

  it "collects on the discounted price, not the plan price" do
    activity = create(:activity)
    plan = create(:contract_type, company: activity.company, activity: activity, price: 100)
    client = create(:client, company: plan.company)
    staff = create(:user, :admin)

    period = Contract.sell!(client: client, contract_type: plan, activity: activity, created_by: staff, discount: 30, collect_payment: true, payment_method: "cash")

    expect(period.payments.first.amount).to eq(70)
    expect(period.contract).to be_paid
  end

  it "falls back to cash when given an unsupported payment method (card is out of scope)" do
    activity = create(:activity)
    plan = create(:contract_type, company: activity.company, activity: activity, price: 50)
    client = create(:client, company: plan.company)
    staff = create(:user, :admin)

    period = Contract.sell!(client: client, contract_type: plan, activity: activity, created_by: staff, collect_payment: true, payment_method: "card")

    expect(period.payments.first.payment_method).to eq("cash")
  end

  it "leaves the abonnement unpaid and creates no payment when collect_payment is not set" do
    activity = create(:activity)
    plan = create(:contract_type, company: activity.company, activity: activity, price: 89)
    client = create(:client, company: plan.company)
    staff = create(:user, :admin)

    period = Contract.sell!(client: client, contract_type: plan, activity: activity, created_by: staff)

    expect(period.payments.first).to be_nil
    expect(period.contract).to be_unpaid
  end

  it "creates a second, independent contract when the same plan is issued again for a different activity" do
    company = create(:company)
    yoga = create(:activity, company: company, name: "Yoga")
    crossfit = create(:activity, company: company, name: "CrossFit")
    plan = create(:contract_type, company: company, activity: yoga, price: 89)
    create(:contract_type_activity, contract_type: plan, activity: crossfit, price: 89)
    client = create(:client, company: plan.company)
    staff = create(:user, :admin)

    first = Contract.sell!(client: client, contract_type: plan, activity: yoga, created_by: staff)
    second = Contract.sell!(client: client, contract_type: plan, activity: crossfit, created_by: staff)

    expect(first.contract.id).not_to eq(second.contract.id)
    expect(client.contracts.count).to eq(2)
  end

  it "adds a new period to the same contract when the same plan+activity is issued again" do
    activity = create(:activity)
    plan = create(:contract_type, company: activity.company, activity: activity, price: 89)
    client = create(:client, company: plan.company)
    staff = create(:user, :admin)

    first = Contract.sell!(client: client, contract_type: plan, activity: activity, created_by: staff)
    second = Contract.sell!(client: client, contract_type: plan, activity: activity, created_by: staff)

    expect(first.contract.id).to eq(second.contract.id)
    expect(client.contracts.count).to eq(1)
    expect(first.contract.contract_periods.count).to eq(2)
  end

  it "takes each activity's own price from the plan's grid, not a flat plan price" do
    company = create(:company)
    boxe = create(:activity, company: company, name: "Boxe")
    pilates = create(:activity, company: company, name: "Pilates")
    plan = create(:contract_type, company: company, activity: boxe, price: 50)
    create(:contract_type_activity, contract_type: plan, activity: pilates, price: 70)
    client = create(:client, company: plan.company)
    staff = create(:user, :admin)

    boxe_period = Contract.sell!(client: client, contract_type: plan, activity: boxe, created_by: staff)
    pilates_period = Contract.sell!(client: client, contract_type: plan, activity: pilates, created_by: staff)

    expect(boxe_period.final_price).to eq(50)
    expect(pilates_period.final_price).to eq(70)
  end

  it "refuses to sell a plan for an activity it has no price for" do
    plan = create(:contract_type, price: 89)
    unpriced = create(:activity, company: plan.company, name: "Aquagym")
    client = create(:client, company: plan.company)
    staff = create(:user, :admin)

    expect { Contract.sell!(client: client, contract_type: plan, activity: unpriced, created_by: staff) }
      .to raise_error(ApplicationRecord::Refused, /Aquagym/)
    expect(client.contracts).to be_empty
  end

  it "ignores a later catalogue change — the price is frozen at subscription time" do
    activity = create(:activity)
    plan = create(:contract_type, company: activity.company, activity: activity, price: 70)
    client = create(:client, company: plan.company)
    staff = create(:user, :admin)

    contract = Contract.sell!(client: client, contract_type: plan, activity: activity, created_by: staff).contract
    plan.contract_type_activities.find_by(activity: activity).update!(price: 80)
    # Re-saving the period is what used to silently re-price it (an encaissement
    # does exactly this).
    contract.current_period.update!(payment_status: :paid)

    expect(contract.reload.final_price).to eq(70)
  end
end
