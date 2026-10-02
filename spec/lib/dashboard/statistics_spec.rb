require "rails_helper"

RSpec.describe Dashboard::Statistics do
  it "counts clients, active contracts, and today's schedule activity" do
    company = create(:company)
    create(:client, company: company, active: true)
    create(:client, company: company, active: false)

    plan = create(:contract_type, company: company)
    member = create(:client, company: company)
    create(:contract, client: member, contract_type: plan)

    activity = create(:activity, company: company, name: "Yoga")
    session = create(:session, activity: activity, company: company,
                                starts_at: Time.current.change(hour: 9), ends_at: Time.current.change(hour: 10),
                                capacity: 5)
    booking = create(:booking, session: session, client: member, status: :confirmed)
    create(:attendance_record, booking: booking, status: :present)

    result = described_class.call(company: company)

    expect(result[:total_clients]).to eq(2)
    expect(result[:active_contracts]).to eq(1)
    expect(result[:todays_bookings]).to eq(1)
    expect(result[:todays_attendance]).to eq(1)

    expect(result[:todays_schedule].size).to eq(1)
    schedule_entry = result[:todays_schedule].first
    expect(schedule_entry[:id]).to eq(session.id)
    expect(schedule_entry[:activity_name]).to eq("Yoga")
    expect(schedule_entry[:confirmed_count]).to eq(1)
    expect(schedule_entry[:capacity]).to eq(5)
    expect(schedule_entry[:status]).to eq("scheduled")
  end

  it "computes outstanding payments from unpaid bookings and unpaid contract periods" do
    company = create(:company)
    plan = create(:contract_type, company: company, price: 150)
    client = create(:client, company: company)
    create(:contract, client: client, contract_type: plan, discount: 20) # final_price 130, unpaid

    activity = create(:activity, company: company)
    session = create(:session, activity: activity, company: company, price: 45)
    create(:booking, session: session, client: client, amount: 45, payment_status: :unpaid)

    result = described_class.call(company: company)

    expect(result[:outstanding_payments]).to eq(175)
  end

  it "lists contracts expiring within the notification window" do
    company = create(:company)
    plan = create(:contract_type, company: company, name: "Plan A")
    soon_client = create(:client, company: company, first_name: "Amina", last_name: "Trabelsi")
    expiring_contract = create(:contract, client: soon_client, contract_type: plan, status: :active,
                                           expires_at: 3.days.from_now)

    far_client = create(:client, company: company)
    create(:contract, client: far_client, contract_type: plan, status: :active, expires_at: 20.days.from_now)

    result = described_class.call(company: company)

    expect(result[:contracts_expiring].size).to eq(1)
    entry = result[:contracts_expiring].first
    expect(entry[:id]).to eq(expiring_contract.id)
    expect(entry[:client_name]).to eq("Amina Trabelsi")
    expect(entry[:plan_name]).to eq("Plan A")
  end

  it "lists recent payments and recent clients" do
    company = create(:company)
    plan = create(:contract_type, company: company)

    client_a = create(:client, company: company, first_name: "Amina")
    period_a = create(:contract, client: client_a, contract_type: plan).current_period
    create(:payment, company: company, client: client_a, contract_period: period_a, amount: 60, status: :paid)

    client_b = create(:client, company: company, first_name: "Youssef")
    period_b = create(:contract, client: client_b, contract_type: plan).current_period
    create(:payment, company: company, client: client_b, contract_period: period_b, amount: 40, status: :paid)

    result = described_class.call(company: company)

    expect(result[:recent_payments].size).to eq(2)
    expect(result[:recent_payments].map { |p| p[:client_name] }).to contain_exactly("Amina Ben Ali", "Youssef Ben Ali")
    expect(result[:recent_clients].map { |c| c[:full_name] }).to contain_exactly("Amina Ben Ali", "Youssef Ben Ali")
  end

  describe "the attention block" do
    def row(result, key)
      result[:attention].find { |r| r[:key] == key }
    end

    it "counts only work that is still live, and prices the unpaid" do
      company = create(:company)
      plan = create(:contract_type, company: company, price: 100)

      # expires in a fortnight, paid — chase the renewal, not the money
      soon = create(:contract, client: create(:client, company: company), contract_type: plan)
      soon.current_period.update!(expires_at: 14.days.from_now, payment_status: :paid)

      # live but never paid
      owing = create(:contract, client: create(:client, company: company), contract_type: plan)
      owing.current_period.update!(expires_at: 60.days.from_now, payment_status: :unpaid)

      # ran out yesterday and nobody noticed
      lapsed = create(:contract, client: create(:client, company: company), contract_type: plan)
      lapsed.current_period.update!(expires_at: 1.day.ago, payment_status: :paid)

      result = described_class.call(company: company)

      expect(row(result, "expiring")[:count]).to eq(1)
      expect(row(result, "unpaid")[:count]).to eq(1)
      expect(row(result, "unpaid")[:amount]).to eq(owing.current_period.final_price.to_f)
      expect(row(result, "expired")[:count]).to eq(1)
    end

    it "ignores a superseded period — last season's expiry is history, not work" do
      company = create(:company)
      plan = create(:contract_type, company: company, price: 100)
      contract = create(:contract, client: create(:client, company: company), contract_type: plan)
      contract.current_period.update!(starts_at: 1.year.ago, expires_at: 6.months.ago, payment_status: :unpaid)
      create(:contract_period, contract: contract, starts_at: 1.day.ago,
                                expires_at: 1.year.from_now, status: :active, payment_status: :paid)

      result = described_class.call(company: company)

      expect(row(result, "expired")[:count]).to eq(0)
      expect(row(result, "unpaid")[:count]).to eq(0)
    end

    it "flags today's sessions that nobody is running" do
      company = create(:company)
      activity = create(:activity, company: company)
      create(:session, activity: activity, company: company, coach: nil,
                        starts_at: Time.current.change(hour: 9), ends_at: Time.current.change(hour: 10))
      create(:session, activity: activity, company: company, coach: create(:coach, company: company),
                        starts_at: Time.current.change(hour: 11), ends_at: Time.current.change(hour: 12))

      result = described_class.call(company: company)

      expect(row(result, "sessions_without_coach")[:count]).to eq(1)
    end

    it "keeps a row at zero rather than dropping it, so the caller can say all clear" do
      result = described_class.call(company: create(:company))

      expect(result[:attention].map { |r| r[:key] })
        .to eq(%w[expiring unpaid expired sessions_without_coach])
      expect(result[:attention].map { |r| r[:count] }).to all(eq(0))
    end
  end

  describe "the chart's twelve months" do
    it "comes back with the rest of the dashboard, so one call draws the page" do
      company = create(:company)

      by_month = described_class.call(company: company)[:revenue_by_month]

      expect(by_month.length).to eq(12)
      expect(by_month.last[:month]).to eq(Date.current.beginning_of_month)
    end

    it "is empty for someone who may not see money" do
      company = create(:company)

      expect(described_class.call(company: company, revenue: false)[:revenue_by_month]).to eq([])
    end
  end

  describe "revenue: false" do
    it "keeps the volumes and drops every figure in money" do
      company = create(:company)
      plan = create(:contract_type, company: company, price: 100)
      client = create(:client, company: company)
      contract = create(:contract, client: client, contract_type: plan)
      contract.current_period.update!(status: :active, payment_status: :unpaid, expires_at: 90.days.from_now)
      create(:payment, client: client, company: company, status: :paid, amount: 100)

      result = described_class.call(company: company, revenue: false)

      expect(result[:total_clients]).to eq(1)
      expect(result[:outstanding_payments]).to be_nil
      expect(result[:recent_payments]).to eq([])

      unpaid = result[:attention].find { |r| r[:key] == "unpaid" }
      expect(unpaid[:count]).to eq(1)
      expect(unpaid[:amount]).to be_nil
    end
  end
end
