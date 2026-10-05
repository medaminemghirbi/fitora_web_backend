class RecurringScheduleSerializer
  def initialize(schedule)
    @schedule = schedule
  end

  def as_json(*)
    {
      id: schedule.id,
      activity_id: schedule.activity_id,
      activity_name: schedule.activity.name,
      coach_id: schedule.coach_id,
      coach_name: schedule.coach&.full_name,
      space_id: schedule.space_id,
      space_name: schedule.space&.name,
      weekdays: schedule.weekdays,
      start_time: schedule.start_time.strftime("%H:%M"),
      recurrence_type: schedule.recurrence_type,
      starts_on: schedule.starts_on,
      ends_on: schedule.ends_on,
      active: schedule.active,
      generated_sessions_count: schedule.sessions.count
    }
  end

  private

  attr_reader :schedule
end
