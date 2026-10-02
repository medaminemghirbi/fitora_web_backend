require "rails_helper"

RSpec.describe Payment, ".collect!" do
  it "records a payment against a booking and marks it paid when the amount covers it in full" do
    company = create(:company)
    client = create(:client, company: company)
    session = create(:session, activity: create(:activity, company: company), price: 40)
    booking = create(:booking, client: client, session: session, amount: 40, payment_status: :unpaid)
    staff = create(:user, :admin)

    described_class.collect!(client: client, company: company, created_by: staff, amount: 40, payment_method: :cash, booking: booking)

    expect(booking.reload).to be_paid
  end

  it "settles a contract period in full when no amount is given" do
    plan = create(:contract_type, price: 100)
    client = create(:client, company: plan.company)
    period = create(:contract, client: client, contract_type: plan, discount: 10).current_period
    staff = create(:user, :admin)

    payment = described_class.collect!(
      client: client, company: plan.company, created_by: staff,
      amount: nil, payment_method: :cash, contract_period: period
    )

    expect(payment.amount).to eq(90)
    expect(period.reload).to be_paid
  end

  it "rejects a payment linked to nothing at all" do
    company = create(:company)
    client = create(:client, company: company)
    staff = create(:user, :admin)

    expect { described_class.collect!(client: client, company: company, created_by: staff, amount: 10, payment_method: :cash) }
      .to raise_error(ActiveRecord::RecordInvalid, /must be linked to a contract or booking/)
  end
end
