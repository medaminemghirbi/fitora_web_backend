require "rails_helper"

# The database keeps a coach out of two places at once
# (Session::COACH_OVERLAP_CONSTRAINT); the model only has to say so in words.
RSpec.describe Session, "coach overlap" do
  let(:company) { create(:company) }
  let(:coach) { create(:coach, company: company) }
  let(:starts_at) { 2.days.from_now.change(hour: 18) }

  def session_for(activity, from, to)
    company.sessions.new(activity: activity, coach: coach, starts_at: from, ends_at: to, capacity: 10, price: 20)
  end

  it "rejects a coach's overlapping session with a friendly error, even for different activities" do
    activity_a = create(:activity, company: company)
    activity_b = create(:activity, company: company)
    expect(session_for(activity_a, starts_at, starts_at + 1.hour).save).to be(true)

    second = session_for(activity_b, starts_at + 30.minutes, starts_at + 90.minutes)

    expect(second.save).to be(false)
    expect(second.errors.full_messages).to eq([ "Coach already has a session at that time." ])
  end

  it "raises it as a validation error from save!" do
    activity = create(:activity, company: company)
    session_for(activity, starts_at, starts_at + 1.hour).save!

    expect { session_for(activity, starts_at + 30.minutes, starts_at + 90.minutes).save! }
      .to raise_error(ActiveRecord::RecordInvalid, /Coach already has a session at that time/)
  end

  it "allows back-to-back non-overlapping sessions for the same coach" do
    activity = create(:activity, company: company)

    expect(session_for(activity, starts_at, starts_at + 1.hour).save).to be(true)
    expect(session_for(activity, starts_at + 1.hour, starts_at + 2.hours).save).to be(true)
  end

  it "rejects an update that would overlap another of the coach's sessions" do
    activity = create(:activity, company: company)
    create(:session, activity: activity, company: company, coach: coach, starts_at: starts_at, ends_at: starts_at + 1.hour)
    session = create(:session, activity: activity, company: company, coach: coach,
                               starts_at: starts_at + 2.hours, ends_at: starts_at + 3.hours)

    expect(session.update(starts_at: starts_at + 30.minutes, ends_at: starts_at + 90.minutes)).to be(false)
    expect(session.errors.full_messages).to eq([ "Coach already has a session at that time." ])
    expect(session.reload.starts_at).to eq(starts_at + 2.hours)
  end
end
