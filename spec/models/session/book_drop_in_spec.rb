require "rails_helper"

# A studio's first contact with someone is a trial or a single paid session,
# booked by the desk before any contract exists.
RSpec.describe Session, "#book! without a contract" do
  let(:company) { create(:company) }
  let(:activity) { create(:activity, company: company, session_format: :individual, capacity: 1) }
  let(:session) { create(:session, company: company, activity: activity, capacity: 1, price: 45) }
  let(:prospect) { create(:client, company: company) }

  it "books a single session at the session's price, owed until paid" do
    booking = session.book!(prospect, drop_in: true)

    expect(booking).to be_confirmed
    expect(booking.amount).to eq(45)
    expect(booking).to be_unpaid
    expect(booking.trial).to be(false)
    expect(booking.contract).to be_nil
  end

  it "books a trial for free, and only once per person per gym" do
    booking = session.book!(prospect, trial: true)

    expect(booking.trial).to be(true)
    expect(booking.amount).to eq(0)
    expect(booking).to be_paid

    other = create(:session, company: company, activity: activity, capacity: 1,
                             starts_at: 3.days.from_now, ends_at: 3.days.from_now + 1.hour)
    expect { other.book!(prospect, trial: true) }.to raise_error(ApplicationRecord::Refused, /already had a trial/)
  end

  it "allows a second trial once the first was cancelled" do
    session.book!(prospect, trial: true).cancel!
    other = create(:session, company: company, activity: activity, capacity: 1,
                             starts_at: 3.days.from_now, ends_at: 3.days.from_now + 1.hour)

    expect(other.book!(prospect, trial: true).trial).to be(true)
  end

  it "spends the member's credit instead when a contract already covers the session" do
    plan = create(:contract_type, company: company, activity: activity)
    create(:contract, client: prospect, contract_type: plan, company: company, activity: activity)

    booking = session.book!(prospect, drop_in: true)

    expect(booking.contract).to be_present
    expect(booking.amount).to eq(0)
  end

  it "is never open to a member booking from their own app" do
    expect { session.book!(prospect, by: :member, drop_in: true) }
      .to raise_error(ApplicationRecord::Refused, /needs an active contract/)
  end

  it "is refused when the gym has turned drop-ins off" do
    company.update!(settings: { features: { drop_in: false } })

    expect { session.reload.book!(prospect, drop_in: true) }
      .to raise_error(ApplicationRecord::Refused, /needs an active contract/)
  end

  it "takes no place in a queue: a full session is full" do
    company.update!(settings: { features: { waitlist: true } })
    session.book!(create(:client, company: company), trial: true)

    expect { session.reload.book!(prospect, drop_in: true) }.to raise_error(ApplicationRecord::Refused, /full/)
  end

  it "still refuses without a contract when nothing asked for a drop-in" do
    expect { session.book!(prospect) }.to raise_error(ApplicationRecord::Refused, /needs an active contract/)
  end
end
