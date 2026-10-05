require "rails_helper"

RSpec.describe Contract, "#pause! / #resume!" do
  let(:company) { create(:company) }
  let(:activity) { create(:activity, company: company) }
  let(:plan) { create(:contract_type, company: company, activity: activity) }
  let(:client) { create(:client, company: company) }
  let(:contract) do
    create(:contract, client: client, contract_type: plan, company: company, activity: activity,
                      starts_at: 10.days.ago, expires_at: 20.days.from_now)
  end

  it "puts the membership on hold, and nothing books against it" do
    contract.pause!

    expect(contract.reload).to be_paused
    expect(contract.usable_for?(activity: activity)).to be(false)
    session = create(:session, company: company, activity: activity)
    expect { session.book!(client) }.to raise_error(ApplicationRecord::Refused, /paused/)
  end

  it "gives back the time it was held on resume" do
    expires_at = contract.expires_at
    contract.pause!

    travel 15.days do
      contract.resume!

      expect(contract.reload).not_to be_paused
      expect(contract.expires_at).to be_within(1.minute).of(expires_at + 15.days)
      expect(contract.usable_for?(activity: activity)).to be(true)
    end
  end

  it "moves a renewal queued behind it by the same amount" do
    contract.update!(expires_at: 5.days.from_now)
    renewal = contract.renew!
    contract.pause!

    travel 7.days do
      contract.resume!

      expect(renewal.reload.starts_at).to be_within(1.minute).of(contract.reload.expires_at)
    end
  end

  it "refuses to pause twice, or to resume what is not paused" do
    expect { contract.resume! }.to raise_error(ApplicationRecord::Refused, /not paused/)
    contract.pause!
    expect { contract.pause! }.to raise_error(ApplicationRecord::Refused, /already paused/)
  end

  it "refuses to pause a term that has already run out" do
    lapsed = create(:contract, client: create(:client, company: company), contract_type: plan, company: company,
                               activity: activity, starts_at: 40.days.ago, expires_at: 2.days.ago)

    expect { lapsed.pause! }.to raise_error(ApplicationRecord::Refused, /already ended/)
  end

  it "is not warned about as expiring while it is on hold" do
    soon = create(:contract, client: create(:client, company: company), contract_type: plan, company: company,
                             activity: activity, starts_at: 20.days.ago, expires_at: 3.days.from_now)
    soon.pause!

    expect(Contract.expiring_soon(within: 14.days)).not_to include(soon)
  end

  it "clears the hold when the contract is cancelled" do
    contract.pause!
    contract.cancel!

    expect(contract.reload.paused_at).to be_nil
  end
end
