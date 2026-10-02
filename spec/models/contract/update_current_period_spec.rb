require "rails_helper"

RSpec.describe Contract, "#update_current_period!" do
  it "updates the start date and re-derives the expiry from the plan's billing period" do
    contract_type = create(:contract_type, billing_period: :monthly)
    contract = create(:contract, contract_type: contract_type, status: :active)
    new_start = 3.days.from_now.to_date

    contract.update_current_period!(starts_on: new_start)

    period = contract.reload.current_period
    expect(period.starts_at.to_date).to eq(new_start)
    expect(period.expires_at.to_date).to eq(new_start + 30.days)
  end

  it "updates the expiry date directly when given" do
    contract = create(:contract, status: :active)
    new_expiry = 60.days.from_now.to_date

    contract.update_current_period!(expires_on: new_expiry)

    expect(contract.reload.current_period.expires_at.to_date).to eq(new_expiry)
  end

  it "updates the discount while the period is unpaid" do
    contract = create(:contract, status: :active, payment_status: :unpaid)

    contract.update_current_period!(discount: 15)

    expect(contract.reload.current_period.discount).to eq(15.0)
  end

  it "rejects a discount change once the period is paid" do
    contract = create(:contract, status: :active, payment_status: :paid)

    expect { contract.update_current_period!(discount: 15) }
      .to raise_error(ApplicationRecord::Refused, "Discount can only change while the subscription is unpaid")
    expect(contract.reload.current_period.discount).to eq(0.0)
  end

  it "rejects editing when the contract has no period at all" do
    contract = create(:contract)
    contract.contract_periods.destroy_all

    expect { contract.update_current_period!(expires_on: 10.days.from_now.to_date) }
      .to raise_error(ApplicationRecord::Refused, "No active subscription to edit")
  end

  it "rejects editing an expired period" do
    contract = create(:contract, status: :expired)

    expect { contract.update_current_period!(expires_on: 10.days.from_now.to_date) }
      .to raise_error(ApplicationRecord::Refused, "This subscription can no longer be edited")
  end

  it "rejects editing a cancelled period" do
    contract = create(:contract, status: :cancelled)

    expect { contract.update_current_period!(expires_on: 10.days.from_now.to_date) }
      .to raise_error(ApplicationRecord::Refused, "This subscription can no longer be edited")
  end

  it "allows editing while the period is pending" do
    contract = create(:contract, status: :pending)

    expect { contract.update_current_period!(expires_on: 20.days.from_now.to_date) }.not_to raise_error
  end

  it "returns a friendly error for an unparseable date" do
    contract = create(:contract, status: :active)

    expect { contract.update_current_period!(starts_on: "not-a-date") }
      .to raise_error(ApplicationRecord::Refused, "Invalid date")
  end

  it "raises the record's validation error when the update is invalid" do
    contract = create(:contract, status: :active, payment_status: :unpaid)

    expect { contract.update_current_period!(discount: -5) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(contract.reload.current_period.discount).to eq(0.0)
  end
end
