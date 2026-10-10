require "rails_helper"

RSpec.describe RecurringSchedule do
  it "rejects an end date before the start date" do
    schedule = build(:recurring_schedule, starts_on: Date.new(2025, 3, 10), ends_on: Date.new(2025, 3, 5))

    expect(schedule).not_to be_valid
    expect(schedule.errors[:ends_on]).to be_present
  end

  it "rejects weekdays outside the 0-6 range" do
    schedule = build(:recurring_schedule, weekdays: [ 1, 7 ])

    expect(schedule).not_to be_valid
    expect(schedule.errors[:weekdays]).to be_present
  end

  it "refuses an activity that belongs to another gym" do
    schedule = build(:recurring_schedule, company: create(:company))

    expect(schedule).not_to be_valid
    expect(schedule.errors[:activity]).to be_present
  end

  describe "#generation_end_date" do
    it "returns ends_on when it falls within the generation horizon" do
      travel_to Date.new(2025, 1, 1) do
        schedule = build(:recurring_schedule, ends_on: Date.new(2025, 2, 1))
        expect(schedule.generation_end_date).to eq(Date.new(2025, 2, 1))
      end
    end

    it "caps at the generation horizon when ends_on is further out" do
      travel_to Date.new(2025, 1, 1) do
        schedule = build(:recurring_schedule, ends_on: Date.new(2026, 1, 1))
        expect(schedule.generation_end_date).to eq(Date.current + RecurringSchedule::GENERATION_HORIZON)
      end
    end
  end

  it "nullifies its sessions' reference instead of deleting them when destroyed" do
    schedule = create(:recurring_schedule)
    session = create(:session, activity: schedule.activity, company: schedule.company, recurring_schedule: schedule)

    schedule.destroy

    expect(session.reload.recurring_schedule_id).to be_nil
  end

  describe ".active" do
    it "only returns active schedules" do
      active = create(:recurring_schedule, active: true)
      inactive = create(:recurring_schedule, active: false)

      expect(RecurringSchedule.active).to include(active)
      expect(RecurringSchedule.active).not_to include(inactive)
    end
  end

  describe "coach boundary" do
    it "rejects another gym's coach" do
      schedule = build(:recurring_schedule, coach: create(:coach))

      expect(schedule).not_to be_valid
      expect(schedule.errors[:coach]).to include("must belong to this gym")
    end

    it "accepts its own gym's coach" do
      activity = create(:activity)
      schedule = build(:recurring_schedule, activity: activity, coach: create(:coach, company: activity.company))

      expect(schedule).to be_valid
    end
  end
end
