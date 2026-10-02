require "rails_helper"

RSpec.describe Contract, "#cancel!" do
  it "cancels the contract's current period" do
    contract = create(:contract, status: :active)

    contract.cancel!

    expect(contract.reload).to be_cancelled
  end

  it "cancels a pending contract's current period too" do
    contract = create(:contract, status: :pending)

    contract.cancel!

    expect(contract.reload).to be_cancelled
  end

  it "rejects cancelling an already cancelled contract" do
    contract = create(:contract, status: :cancelled)

    expect { contract.cancel! }.to raise_error(ApplicationRecord::Refused, "This contract is already cancelled.")
  end
end
