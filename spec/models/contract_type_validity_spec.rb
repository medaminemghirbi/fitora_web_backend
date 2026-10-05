require "rails_helper"

# A carnet's own lifetime: "10 séances valables 8 semaines".
RSpec.describe ContractType, "custom validity" do
  let(:company) { create(:company) }

  it "lasts validity_days when the period is custom" do
    plan = create(:contract_type, company: company, billing_period: :custom, validity_days: 56)

    expect(plan.duration_days).to eq(56)
  end

  it "requires a validity for a custom period" do
    plan = build(:contract_type, company: company, billing_period: :custom, validity_days: nil)

    expect(plan).not_to be_valid
    expect(plan.errors[:validity_days]).to be_present
  end

  it "drops a stale validity once the period is fixed again" do
    plan = create(:contract_type, company: company, billing_period: :custom, validity_days: 56)
    plan.update!(billing_period: :monthly)

    expect(plan.reload.validity_days).to be_nil
    expect(plan.duration_days).to eq(30)
  end

  it "sells a period that ends validity_days after it starts" do
    activity = create(:activity, company: company)
    plan = create(:contract_type, company: company, activity: activity, billing_period: :custom, validity_days: 42)
    client = create(:client, company: company)

    period = Contract.sell!(client: client, contract_type: plan, activity: activity, created_by: company.admin)

    expect((period.expires_at.to_date - period.starts_at.to_date).to_i).to eq(42)
  end

  it "refuses a nonsensical validity" do
    expect(build(:contract_type, company: company, billing_period: :custom, validity_days: 0)).not_to be_valid
    expect(build(:contract_type, company: company, billing_period: :custom, validity_days: 5000)).not_to be_valid
  end
end
