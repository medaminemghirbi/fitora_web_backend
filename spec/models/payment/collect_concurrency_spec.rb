require "rails_helper"

RSpec.describe Payment, ".collect! under concurrency" do
  let(:company) { create(:company) }
  let(:client) { create(:client, company: company) }
  let(:contract) { create(:contract, client: client, contract_type: create(:contract_type, company: company), payment_status: :unpaid) }
  let(:period) { contract.current_period }

  # Each thread loads its own copy of the period, as two requests would.
  def settle
    Payment.collect!(client: client, company: company, created_by: company.admin,
                     payment_method: "cash", contract_period: ContractPeriod.find(period.id))
    :paid
  rescue ApplicationRecord::Refused => e
    e.message
  end

  it "records a double click once" do
    results = 2.times.map do
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { settle } }
    end.map(&:value)

    expect(results).to contain_exactly(:paid, "This is already paid.")
    expect(period.payments.count).to eq(1)
  end

  it "will not settle another gym's period for the same person" do
    other_gym = create(:company)
    client.join!(other_gym)

    expect {
      Payment.collect!(client: client, company: other_gym, created_by: other_gym.admin,
                       payment_method: "cash", contract_period: period)
    }.to raise_error(ActiveRecord::RecordInvalid, /belongs to another gym/)
    expect(period.reload).to be_unpaid
  end
end

RSpec.describe "POST /api/v1/payments across gyms", type: :request do
  it "cannot reach a period another gym sold the same person" do
    gym_a = create(:company)
    gym_b = create(:company)
    member = create(:client, company: gym_a)
    member.join!(gym_b)
    contract = create(:contract, client: member, contract_type: create(:contract_type, company: gym_a), payment_status: :unpaid)

    post "/api/v1/payments", params: { client_id: member.id, contract_period_id: contract.current_period.id, payment_method: "cash" },
                             headers: auth_headers(gym_b.admin)

    expect(contract.current_period.reload).to be_unpaid
    expect(Payment.where(contract_period: contract.current_period)).to be_empty
  end
end

RSpec.describe Invoice, ".next_number" do
  it "hands out the first number of a year once, however many ask at once" do
    numbers = travel_to(Time.zone.local(2031, 1, 1, 9)) do
      4.times.map do
        Thread.new { ActiveRecord::Base.connection_pool.with_connection { described_class.next_number } }
      end.map(&:value)
    end

    expect(numbers.uniq.size).to eq(4)
    expect(numbers).to include("FIT-2031-0001")
  end

  it "keeps counting past 9999" do
    ActiveRecord::Base.connection.execute("INSERT INTO invoice_sequences (year, last_value) VALUES (2032, 9999)")

    expect(described_class.next_number(now: Time.zone.local(2032, 6, 1))).to eq("FIT-2032-10000")
  end
end
