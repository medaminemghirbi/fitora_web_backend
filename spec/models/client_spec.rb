require "rails_helper"

RSpec.describe Client do
  let(:company) { create(:company) }

  it "downcases and strips the email before validation" do
    client = create(:client, company: company, email: "  Test@Example.COM ")
    expect(client.email).to eq("test@example.com")
  end

  it "requires first name, last name and phone" do
    client = build(:client, company: company, first_name: nil, last_name: nil, phone: nil)
    expect(client).not_to be_valid
    expect(client.errors[:first_name]).to be_present
    expect(client.errors[:last_name]).to be_present
    expect(client.errors[:phone]).to be_present
  end

  it "treats the email as the person: unique across the platform, login or not" do
    create(:client, company: company, email: "dup@example.com")

    dupe = build(:client, email: "dup@example.com")
    expect(dupe).not_to be_valid
    expect(dupe.errors[:email]).to be_present
  end

  it "leaves a gym free to record several walk-ins with no email at all" do
    create(:client, company: company, email: nil)
    expect(build(:client, email: nil)).to be_valid
  end

  describe "belonging to several gyms" do
    it "joins a second gym without a second account" do
      client = create(:client, company: company)
      other = create(:company)

      client.join!(other)

      expect(client.companies).to contain_exactly(company, other)
      expect(Client.where(email: client.email).count).to eq(1)
    end

    it "is idempotent: joining twice leaves one membership" do
      client = create(:client, company: company)

      expect { client.join!(company) }.not_to change(Membership, :count)
    end

    it "keeps each gym's view of the person separate" do
      client = create(:client, company: company, notes: "Suivi kiné")
      other = create(:company)
      client.join!(other)

      expect(client.membership_for(company).notes).to eq("Suivi kiné")
      expect(client.membership_for(other).notes).to be_nil
    end

    it "never shows one gym another gym's contracts" do
      client = create(:client, company: company)
      other = create(:company)
      client.join!(other)
      activity = create(:activity, company: other)
      plan = create(:contract_type, company: other, activity: activity)
      create(:contract, client: client, company: other, contract_type: plan, activity: activity)

      expect(client.contracts_for(other).count).to eq(1)
      expect(client.contracts_for(company)).to be_empty
      expect(client.current_contract(company)).to be_nil
    end
  end

  describe "the account a gym may enable" do
    it "is off by default — a walk-in the gym wrote down is still a member" do
      expect(create(:client, company: company).login_enabled?).to be false
    end

    it "is on once the gym sets a password" do
      client = create(:client, company: company)
      client.update!(password: "password123")
      expect(client.reload.login_enabled?).to be true
      expect(client.authenticate("password123")).to be_truthy
    end

    it "refuses a password too short to be one" do
      client = build(:client, company: company, password: "short")
      expect(client).not_to be_valid
      expect(client.errors[:password]).to be_present
    end

    it "refuses an account with no email — that is where the invitation goes" do
      client = build(:client, company: company, email: nil, password: "password123")
      expect(client).not_to be_valid
      expect(client.errors[:email]).to be_present
    end
  end

  it "builds the full name from first and last name" do
    client = build(:client, first_name: "Ahmed", last_name: "Ben Ali")
    expect(client.full_name).to eq("Ahmed Ben Ali")
  end

  describe ".active" do
    it "only returns active clients" do
      active = create(:client, company: company, active: true)
      inactive = create(:client, company: company, active: false)

      expect(Client.active).to include(active)
      expect(Client.active).not_to include(inactive)
    end
  end

  describe ".search" do
    it "matches by first name, last name, phone or email, case-insensitively" do
      match = create(:client, company: company, first_name: "Amine", last_name: "Trabelsi",
                               phone: "20111222", email: "amine@example.com")
      other = create(:client, company: company, first_name: "Sara", last_name: "Gharbi",
                               phone: "20333444", email: "sara@example.com")

      expect(Client.search("amine")).to contain_exactly(match)
      expect(Client.search("TRABELSI")).to contain_exactly(match)
    end

    it "returns everyone when the term is blank" do
      create_list(:client, 2, company: company)
      expect(Client.search("").count).to eq(2)
      expect(Client.search(nil).count).to eq(2)
    end
  end

  describe "#current_contract" do
    it "returns the active contract in force, not a renewal queued behind it" do
      client = create(:client, company: company)
      running = create(:contract, client: client, contract_type: create(:contract_type, company: company),
                                  status: :active, starts_at: 25.days.ago, expires_at: 5.days.from_now)
      running.renew!

      expect(client.current_contract).to eq(running)
    end

    it "ignores contracts that aren't active" do
      client = create(:client, company: company)
      create(:contract, client: client, contract_type: create(:contract_type, company: company), status: :cancelled)

      expect(client.current_contract).to be_nil
    end
  end

  describe "#outstanding_balance" do
    it "sums unpaid bookings and contracts, net of payments already received" do
      client = create(:client, company: company)
      session = create(:session, activity: create(:activity, company: company))
      booking = create(:booking, client: client, session: session, amount: 20, payment_status: :unpaid)
      contract = create(:contract, client: client, contract_type: create(:contract_type, company: company, price: 89),
                                    status: :active, payment_status: :unpaid)

      expect(client.outstanding_balance).to eq(20 + 89)

      create(:payment, client: client, company: company, booking: booking, contract: nil,
                        amount: 20, status: :paid)
      create(:payment, client: client, company: company, contract: contract,
                        booking: nil, amount: 89, status: :paid)

      expect(client.reload.outstanding_balance).to eq(0)
    end

    it "never goes negative when payments exceed what's owed" do
      client = create(:client, company: company)
      session = create(:session, activity: create(:activity, company: company))
      booking = create(:booking, client: client, session: session, amount: 20, payment_status: :unpaid)
      create(:payment, client: client, company: company, booking: booking, contract: nil,
                        amount: 50, status: :paid)

      expect(client.outstanding_balance).to eq(0)
    end
  end

  describe "#attendance_rate" do
    it "returns nil when there is no attendance history" do
      client = create(:client, company: company)
      expect(client.attendance_rate).to be_nil
    end

    it "returns the percentage of bookings marked present, rounded" do
      client = create(:client, company: company)
      activity = create(:activity, company: company)
      b1 = create(:booking, client: client, session: create(:session, activity: activity))
      b2 = create(:booking, client: client, session: create(:session, activity: activity))
      b3 = create(:booking, client: client, session: create(:session, activity: activity))
      create(:attendance_record, booking: b1, status: :present)
      create(:attendance_record, booking: b2, status: :present)
      create(:attendance_record, booking: b3, status: :absent)

      expect(client.attendance_rate).to eq(67)
    end
  end
end
