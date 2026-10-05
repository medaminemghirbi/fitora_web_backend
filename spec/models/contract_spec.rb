require "rails_helper"

RSpec.describe Contract do
  let(:company) { create(:company) }

  describe "validations" do
    it "allows a contract with no activity — that is the all-access kind" do
      contract = build(:contract, activity: nil)

      expect(contract).to be_valid
      expect(contract).to be_all_access
    end

    it "allows the same client, contract type and activity again — each term is a contract of its own" do
      client = create(:client, company: company)
      contract_type = create(:contract_type, company: company)
      activity = create(:activity, company: company)
      create(:contract, client: client, contract_type: contract_type, company: company, activity: activity)

      second = build(:contract, client: client, contract_type: contract_type, company: company, activity: activity)

      expect(second).to be_valid
    end
  end

  describe "#usable_for?" do
    it "is false when the contract isn't active" do
      contract = create(:contract, status: :pending)
      company = contract.activity.company

      expect(contract.usable_for?(activity: contract.activity)).to be false
    end

    it "is false once the contract has expired, even if its status is still active" do
      contract = create(:contract, status: :active, expires_at: 1.day.ago)
      company = contract.activity.company

      expect(contract.usable_for?(activity: contract.activity)).to be false
    end

    it "is false when the plan is limited and no bookings remain" do
      contract_type = create(:contract_type, unlimited_bookings: false, booking_limit: 10)
      contract = create(:contract, contract_type: contract_type, remaining_bookings: 0)
      company = contract.activity.company

      expect(contract.usable_for?(activity: contract.activity)).to be false
    end

    it "is true for an active, unexpired contract with bookings left, delegating to the plan's access rules" do
      contract_type = create(:contract_type, unlimited_bookings: false, booking_limit: 10)
      contract = create(:contract, contract_type: contract_type, remaining_bookings: 3)
      company = contract.activity.company

      expect(contract.usable_for?(activity: contract.activity)).to be true
    end

    it "is false for any activity other than the one the contract itself was issued for, even one the plan would otherwise allow" do
      contract = create(:contract)
      other_activity = create(:activity, company: contract.company)

      expect(contract.usable_for?(activity: other_activity)).to be false
    end
  end

  describe "#consume_booking!" do
    it "decrements remaining_bookings for a limited plan" do
      contract_type = create(:contract_type, unlimited_bookings: false, booking_limit: 10)
      contract = create(:contract, contract_type: contract_type, remaining_bookings: 5)

      contract.consume_booking!

      expect(contract.reload.remaining_bookings).to eq(4)
    end

    it "does nothing for an unlimited plan" do
      contract = create(:contract, remaining_bookings: nil)

      expect { contract.consume_booking! }.not_to raise_error
      expect(contract.reload.remaining_bookings).to be_nil
    end

    it "does nothing when the contract tracks no session count" do
      contract_type = create(:contract_type, unlimited_bookings: false, booking_limit: 10)
      contract = create(:contract, contract_type: contract_type, remaining_bookings: nil)

      expect { contract.consume_booking! }.not_to raise_error
      expect(contract.reload.remaining_bookings).to be_nil
    end
  end

  describe "#restore_booking!" do
    it "increments remaining_bookings for a limited plan" do
      contract_type = create(:contract_type, unlimited_bookings: false, booking_limit: 10)
      contract = create(:contract, contract_type: contract_type, remaining_bookings: 5)

      contract.restore_booking!

      expect(contract.reload.remaining_bookings).to eq(6)
    end

    it "does nothing for an unlimited plan" do
      contract = create(:contract, remaining_bookings: nil)

      expect { contract.restore_booking! }.not_to raise_error
      expect(contract.reload.remaining_bookings).to be_nil
    end
  end

  describe "#covers_activity?" do
    let(:pilates) { create(:activity, company: company) }
    let(:boxing) { create(:activity, company: company) }
    let(:yoga) { create(:activity, company: company) }
    # The plan is priced for pilates and boxing, and deliberately not yoga —
    # `activity:` is the row the factory seeds, so the plan covers exactly
    # these two and nothing else.
    let(:plan) { create(:contract_type, company: company, activity: pilates) }

    before { create(:contract_type_activity, contract_type: plan, activity: boxing) }

    it "covers only its own activity when it names one" do
      contract = create(:contract, contract_type: plan, activity: pilates)

      expect(contract.covers_activity?(pilates)).to be(true)
      expect(contract.covers_activity?(boxing)).to be(false)
    end

    it "covers every activity on the plan when it names none" do
      contract = create(:contract, contract_type: plan, activity: nil)

      expect(contract.covers_activity?(pilates)).to be(true)
      expect(contract.covers_activity?(boxing)).to be(true)
    end

    it "does not cover an activity the plan itself does not, even all-access" do
      contract = create(:contract, contract_type: plan, activity: nil)

      expect(contract.covers_activity?(yoga)).to be(false)
    end

    it "stops covering an activity once the plan drops it" do
      contract = create(:contract, contract_type: plan, activity: nil)
      plan.contract_type_activities.find_by(activity_id: boxing.id).destroy!

      expect(contract.reload.covers_activity?(boxing)).to be(false)
      expect(contract.covers_activity?(pilates)).to be(true)
    end

    it "is false for a nil activity rather than raising" do
      contract = create(:contract, contract_type: plan, activity: nil)

      expect(contract.covers_activity?(nil)).to be(false)
    end

    it "lists what it covers" do
      named = create(:contract, contract_type: plan, activity: pilates)
      all_access = create(:contract, contract_type: plan, activity: nil)

      expect(named.covered_activities).to contain_exactly(pilates)
      expect(all_access.covered_activities).to contain_exactly(pilates, boxing)
    end
  end

  # A renewal taken before the term runs out is a contract that has not
  # begun, linked back to the one it follows. The running term keeps its
  # dates and its quota until the day it actually ends.
  describe "a chain of terms" do
    let(:quota_plan) { create(:contract_type, unlimited_bookings: false, booking_limit: 10) }

    let!(:running) do
      create(:contract, contract_type: quota_plan,
                        starts_at: 10.days.ago, expires_at: 20.days.from_now, remaining_bookings: 4)
    end

    let!(:queued) do
      create(:contract, contract_type: quota_plan, client: running.client, activity: running.activity,
                        renewed_from: running, starts_at: 20.days.from_now, expires_at: 50.days.from_now,
                        remaining_bookings: 10)
    end

    it "links the renewal back to the term it follows" do
      expect(running.reload.renewal).to eq(queued)
      expect(running.queued_renewals).to eq([ queued ])
      expect(queued.renewed_from).to eq(running)
    end

    it "keeps the running term untouched" do
      expect(running.reload.expires_at.to_date).to eq(20.days.from_now.to_date)
      expect(running.remaining_bookings).to eq(4)
    end

    it "counts only the running term as in force" do
      expect(Contract.in_force).to contain_exactly(running)
    end

    it "is renewed, so it is not running out" do
      expect(Contract.not_renewed).to contain_exactly(queued)
    end

    it "keeps both off history until the renewal starts, then only the renewal" do
      expect(Contract.not_superseded).to contain_exactly(running, queued)

      travel_to(25.days.from_now) do
        expect(Contract.not_superseded).to contain_exactly(queued)
      end
    end

    it "forgets a renewal that was cancelled" do
      queued.cancel!

      expect(running.reload.renewal).to be_nil
      expect(Contract.not_renewed).to include(running)
    end
  end

  describe "invoice reference" do
    it "numbers each salle's contracts in order, per year" do
      first = create(:contract, company: company, contract_type: create(:contract_type, company: company))
      second = create(:contract, company: company, contract_type: create(:contract_type, company: company))
      year = Time.current.year

      expect(first.invoice_ref).to eq("FAC-#{year}-0001")
      expect(second.invoice_ref).to eq("FAC-#{year}-0002")
    end

    it "keeps one counter per salle" do
      create(:contract, company: company, contract_type: create(:contract_type, company: company))
      other = create(:company)
      theirs = create(:contract, company: other, contract_type: create(:contract_type, company: other))

      expect(theirs.invoice_ref).to end_with("-0001")
    end

    it "gives a renewal a reference of its own" do
      running = create(:contract, company: company, contract_type: create(:contract_type, company: company),
                                  starts_at: 25.days.ago, expires_at: 5.days.from_now)

      expect(running.renew!.invoice_ref).not_to eq(running.invoice_ref)
    end
  end
end
