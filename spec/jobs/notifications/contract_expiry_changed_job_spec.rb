require "rails_helper"

RSpec.describe Notifications::ContractExpiryChangedJob do
  it "notifies the admin when the contract is expiring soon" do
    contract = create(:contract, expires_at: 5.days.from_now)
    company = contract.company

    expect { described_class.new.perform(contract.id) }
      .to change { company.admin.notifications.where(kind: "contract_expiring").count }.by(1)
  end

  it "does nothing when the contract is not within the warning window" do
    contract = create(:contract, expires_at: 60.days.from_now)

    expect { described_class.new.perform(contract.id) }.not_to change(Notification, :count)
  end

  it "does nothing when the contract is not active" do
    contract = create(:contract, status: :pending, expires_at: 5.days.from_now)

    expect { described_class.new.perform(contract.id) }.not_to change(Notification, :count)
  end

  it "does nothing when the contract has already been renewed" do
    contract = create(:contract, expires_at: 5.days.from_now)
    contract.renew!

    expect { described_class.new.perform(contract.id) }.not_to change(Notification, :count)
  end

  it "does nothing when the contract no longer exists" do
    expect { described_class.new.perform(SecureRandom.uuid) }.not_to change(Notification, :count)
  end
end
