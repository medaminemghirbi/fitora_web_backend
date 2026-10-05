require "rails_helper"

RSpec.describe Session, "#cancel!" do
  let(:company) { create(:company) }
  let(:activity) { create(:activity, company: company) }
  let(:session) { create(:session, activity: activity, capacity: 1) }
  let(:plan) { create(:contract_type, company: company, activity: activity, unlimited_bookings: false) }

  def member_with_credits(credits)
    client = create(:client, company: company)
    contract = create(:contract, client: client, contract_type: plan, activity: activity, remaining_bookings: credits)
    [ client, contract ]
  end

  it "cancels every seat on it and gives each member their session back" do
    client, contract = member_with_credits(5)
    booking = session.book!(client)
    expect(contract.reload.remaining_bookings).to eq(4)

    expect(session.cancel!).to eq(1)
    expect(booking.reload).to be_cancelled
    expect(contract.reload.remaining_bookings).to eq(5)
  end

  it "empties the queue without handing out sessions nobody spent" do
    company.update!(settings: { features: { waitlist: true } })
    seated, = member_with_credits(5)
    queued, queued_contract = member_with_credits(5)
    session.book!(seated)
    waiting = session.book!(queued)
    expect(waiting).to be_waitlisted

    session.cancel!

    expect(waiting.reload).to be_cancelled
    expect(queued_contract.reload.remaining_bookings).to eq(5)
  end

  it "refuses a session already cancelled" do
    session.update!(status: :cancelled)

    expect { session.cancel! }.to raise_error(ApplicationRecord::Refused, "This session is already cancelled.")
  end
end

RSpec.describe Booking, "#cancel! from a queue" do
  it "gives nothing back for leaving a queue that cost nothing" do
    company = create(:company)
    company.update!(settings: { features: { waitlist: true } })
    activity = create(:activity, company: company)
    session = create(:session, activity: activity, capacity: 1)
    plan = create(:contract_type, company: company, activity: activity, unlimited_bookings: false)
    seated = create(:client, company: company)
    create(:contract, client: seated, contract_type: plan, activity: activity, remaining_bookings: 3)
    queued = create(:client, company: company)
    contract = create(:contract, client: queued, contract_type: plan, activity: activity, remaining_bookings: 3)
    session.book!(seated)
    waiting = session.book!(queued)

    waiting.cancel!

    expect(contract.reload.remaining_bookings).to eq(3)
  end
end
