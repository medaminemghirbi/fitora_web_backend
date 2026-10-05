require "rails_helper"

# A room that can be double-booked is not worth having. These cover the
# validations an admin sees on a form, and the database constraint that
# holds when two requests race past them.
RSpec.describe Session, "in a room" do
  let(:company) { create(:company) }
  let(:activity) { create(:activity, company: company) }
  let(:space) { create(:space, company: company) }

  describe "validations" do
    it "accepts a session with no room at all — rooms are optional" do
      expect(build(:session, company: company, activity: activity, space: nil)).to be_valid
    end

    it "refuses another gym's room" do
      session = build(:session, company: company, activity: activity,
                                space: create(:space, company: create(:company)))

      expect(session).not_to be_valid
      expect(session.errors[:space]).to be_present
    end

    it "refuses a room the activity is not allowed to run in" do
      ring = create(:space, company: company)
      create(:activity_space, activity: activity, space: ring)

      session = build(:session, company: company, activity: activity, space: space)

      expect(session).not_to be_valid
      expect(session.errors[:space]).to be_present
    end

    it "accepts a room the activity named" do
      create(:activity_space, activity: activity, space: space)

      expect(build(:session, company: company, activity: activity, space: space)).to be_valid
    end

    it "refuses to seat more people than the room holds" do
      small = create(:space, company: company, capacity: 6)

      session = build(:session, company: company, activity: activity, space: small, capacity: 10)

      expect(session).not_to be_valid
      expect(session.errors[:capacity].join).to include("6")
    end

    it "accepts a session that fits" do
      small = create(:space, company: company, capacity: 12)

      expect(build(:session, company: company, activity: activity, space: small, capacity: 10)).to be_valid
    end

    it "ignores capacity when the room has no stated ceiling" do
      expect(build(:session, company: company, activity: activity, space: space, capacity: 400)).to be_valid
    end
  end

  describe "the no-overlap constraint" do
    let(:start) { 2.days.from_now.change(hour: 18) }

    def session_in_room(space, starts_at:, ends_at:, status: :scheduled)
      Session.create!(company: company, activity: activity, space: space, capacity: 5, price: 10,
                      status: status, starts_at: starts_at, ends_at: ends_at)
    end

    it "refuses two scheduled sessions in the same room at the same time, as a form error" do
      session_in_room(space, starts_at: start, ends_at: start + 1.hour)

      expect {
        session_in_room(space, starts_at: start + 30.minutes, ends_at: start + 90.minutes)
      }.to raise_error(ActiveRecord::RecordInvalid, /This room already has a session at that time/)
    end

    it "makes a plain save answer false rather than raise" do
      session_in_room(space, starts_at: start, ends_at: start + 1.hour)
      clash = Session.new(company: company, activity: activity, space: space, capacity: 5, price: 10,
                          status: :scheduled, starts_at: start + 30.minutes, ends_at: start + 90.minutes)

      expect(clash.save).to be(false)
      expect(clash.errors[:base]).to include("This room already has a session at that time.")
    end

    it "allows back-to-back sessions in one room" do
      session_in_room(space, starts_at: start, ends_at: start + 1.hour)

      expect {
        session_in_room(space, starts_at: start + 1.hour, ends_at: start + 2.hours)
      }.not_to raise_error
    end

    it "allows the same time in a different room" do
      session_in_room(space, starts_at: start, ends_at: start + 1.hour)

      expect {
        session_in_room(create(:space, company: company), starts_at: start, ends_at: start + 1.hour)
      }.not_to raise_error
    end

    it "allows the same time when neither session names a room" do
      session_in_room(nil, starts_at: start, ends_at: start + 1.hour)

      expect {
        session_in_room(nil, starts_at: start, ends_at: start + 1.hour)
      }.not_to raise_error
    end

    it "frees the room when the session is cancelled" do
      taken = session_in_room(space, starts_at: start, ends_at: start + 1.hour)
      taken.update!(status: :cancelled)

      expect {
        session_in_room(space, starts_at: start, ends_at: start + 1.hour)
      }.not_to raise_error
    end
  end
end
