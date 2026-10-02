require "rails_helper"

RSpec.describe RecurringSchedule, "#generate_sessions!" do
  it "generates a session for every matching weekday within the window" do
    monday = Date.current.next_occurring(:monday)
    schedule = create(:recurring_schedule, weekdays: [ 1 ], starts_on: monday, ends_on: monday + 14.days)

    result = schedule.generate_sessions!

    expect(result[:generated]).to eq(3) # 3 Mondays across a 2-week window inclusive of the start
    expect(schedule.sessions.count).to eq(3)
    expect(schedule.sessions.pluck(:starts_at).map(&:wday).uniq).to eq([ 1 ])
  end

  it "never generates further ahead than the 90-day horizon, even with a much later ends_on" do
    schedule = create(:recurring_schedule, weekdays: [ 0, 1, 2, 3, 4, 5, 6 ], starts_on: Date.current, ends_on: 2.years.from_now.to_date)

    schedule.generate_sessions!

    last_session = schedule.sessions.order(:starts_at).last
    expect(last_session.starts_at.to_date).to be <= (Date.current + RecurringSchedule::GENERATION_HORIZON)
  end

  it "is idempotent — running generation twice does not duplicate sessions" do
    schedule = create(:recurring_schedule, weekdays: [ 1 ], starts_on: Date.current, ends_on: 14.days.from_now.to_date)

    schedule.generate_sessions!
    count_after_first_run = schedule.sessions.count
    schedule.generate_sessions!

    expect(schedule.sessions.count).to eq(count_after_first_run)
  end

  it "records a conflict instead of raising when a generated slot would double-book the coach" do
    monday = Date.current.next_occurring(:monday)
    company = create(:company)
    coach = create(:coach, company: company)
    activity_a = create(:activity, company: company, duration: 60)
    activity_b = create(:activity, company: company, duration: 60)

    # An existing manual session already occupies this coach at this exact
    # time — 18:00 at the gym.
    six_pm = company.time_zone.local(monday.year, monday.month, monday.day, 18)
    create(:session, activity: activity_a, company: company, coach: coach, starts_at: six_pm, ends_at: six_pm + 1.hour)

    schedule = create(:recurring_schedule, activity: activity_b, company: company, coach: coach,
                                            weekdays: [ 1 ], start_time: "18:00", starts_on: monday, ends_on: monday)

    result = schedule.generate_sessions!

    expect(result[:generated]).to eq(0)
    expect(result[:conflicts].size).to eq(1)
    expect(result[:conflicts].first[:error]).to eq("Coach already has a session at that time.")
  end

  it "puts an 18:00 class at 18:00 where the gym is, not at 18:00 UTC" do
    monday = Date.current.next_occurring(:monday)
    company = create(:company, timezone: "Africa/Tunis")
    activity = create(:activity, company: company, duration: 60)
    schedule = create(:recurring_schedule, activity: activity, company: company,
                                           weekdays: [ 1 ], start_time: "18:00", starts_on: monday, ends_on: monday)

    schedule.generate_sessions!

    starts_at = schedule.sessions.first.starts_at
    expect(starts_at.in_time_zone("Africa/Tunis").strftime("%H:%M")).to eq("18:00")
    expect(starts_at.utc.hour).to eq(17)
  end

  it "does not duplicate a class when run again" do
    monday = Date.current.next_occurring(:monday)
    company = create(:company, timezone: "Africa/Tunis")
    activity = create(:activity, company: company, duration: 60)
    schedule = create(:recurring_schedule, activity: activity, company: company,
                                           weekdays: [ 1 ], start_time: "18:00", starts_on: monday, ends_on: monday + 14)

    first = schedule.generate_sessions!
    second = schedule.generate_sessions!

    expect(first[:generated]).to eq(3)
    expect(second[:generated]).to eq(0)
    expect(second[:skipped]).to eq(3)
  end
end
