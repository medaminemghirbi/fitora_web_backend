require "rails_helper"

RSpec.describe RecurringSchedulesGenerateJob do
  # Stubbed on every instance, so what is checked is which schedules the job
  # picks, not what generating does (spec/models/recurring_schedule_spec.rb).
  def generated_ids
    ids = []
    allow_any_instance_of(RecurringSchedule).to receive(:generate_sessions!) { |schedule| ids << schedule.id }
    described_class.new.perform
    ids
  end

  it "generates every active schedule still within its window" do
    active_schedule = create(:recurring_schedule, active: true, ends_on: 10.days.from_now.to_date)
    _expired = create(:recurring_schedule, active: true, starts_on: 10.days.ago.to_date, ends_on: 1.day.ago.to_date)
    _inactive = create(:recurring_schedule, active: false, ends_on: 10.days.from_now.to_date)

    expect(generated_ids).to eq([ active_schedule.id ])
  end

  it "generates every active schedule across every company" do
    schedule_a = create(:recurring_schedule, active: true, ends_on: 5.days.from_now.to_date)
    schedule_b = create(:recurring_schedule, active: true, ends_on: 5.days.from_now.to_date)

    expect(generated_ids).to contain_exactly(schedule_a.id, schedule_b.id)
  end
end
