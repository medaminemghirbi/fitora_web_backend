require "rails_helper"

RSpec.describe Session, "#book!" do
  # Every booking is now settled against the member's contract, so a client
  # needs a plan covering the session's company before they can book.
  def contract_for(client, session)
    plan = create(:contract_type, company: session.company, unlimited_bookings: true)
    create(:contract, client: client, contract_type: plan, activity: session.activity)
  end

  # Each thread loads its own copy of the session, as two requests would.
  def book_concurrently(pairs)
    pairs.map do |client, session|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Session.find(session.id).book!(client)
          true
        rescue ApplicationRecord::Refused
          false
        end
      end
    end.map(&:value)
  end

  it "confirms a booking when the client has a covering contract and capacity is available" do
    session = create(:session, capacity: 2)
    client = create(:client)
    contract_for(client, session)

    booking = session.book!(client)

    expect(booking).to be_confirmed
    expect(booking.contract).to be_present
  end

  it "rejects a booking when the client has no covering contract" do
    session = create(:session, capacity: 2)
    client = create(:client)

    expect { session.book!(client) }
      .to raise_error(ApplicationRecord::Refused, "This client needs an active contract to book this activity.")
  end

  it "rejects a booking once the session is full" do
    session = create(:session, capacity: 1)
    create(:booking, session: session, status: :confirmed)
    client = create(:client)

    expect { session.book!(client) }.to raise_error(ApplicationRecord::Refused, "This session is full.")
  end

  it "rejects a duplicate booking by the same client" do
    session = create(:session, capacity: 5)
    client = create(:client)
    create(:booking, session: session, client: client, status: :confirmed)

    expect { session.book!(client) }
      .to raise_error(ApplicationRecord::Refused, "This client already has a booking for this session.")
  end

  it "rejects booking a cancelled session" do
    session = create(:session, status: :cancelled)
    client = create(:client)

    expect { session.book!(client) }.to raise_error(ApplicationRecord::Refused, "This session has been cancelled.")
  end

  it "does not allow bookings to exceed capacity under concurrent requests" do
    session = create(:session, capacity: 1)
    client_a = create(:client)
    client_b = create(:client)
    contract_for(client_a, session)
    contract_for(client_b, session)

    results = book_concurrently([ [ client_a, session ], [ client_b, session ] ])

    expect(results.count(true)).to eq(1)
    expect(session.reload.confirmed_bookings_count).to eq(1)
  end

  it "does not let a contract's booking credit go negative under concurrent requests against different sessions" do
    company = create(:company)
    client = create(:client, company: company)
    plan = create(:contract_type, company: company, unlimited_bookings: false, booking_limit: 1)
    activity = create(:activity, company: company)
    contract = create(:contract, client: client, contract_type: plan, activity: activity, remaining_bookings: 1)
    session_a = create(:session, activity: activity, capacity: 5)
    session_b = create(:session, activity: session_a.activity, company: session_a.company, capacity: 5)

    results = book_concurrently([ [ client, session_a ], [ client, session_b ] ])

    expect(results.count(true)).to eq(1)
    expect(contract.reload.remaining_bookings).to eq(0)
  end
end
