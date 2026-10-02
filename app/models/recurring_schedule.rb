class RecurringSchedule < ApplicationRecord
  # No-infinite-recurrence guardrail — generation never looks further ahead
  # than this, regardless of ends_on.
  GENERATION_HORIZON = 90.days

  belongs_to :activity
  belongs_to :company
  belongs_to :coach, optional: true

  has_many :sessions, dependent: :nullify

  enum :recurrence_type, { weekly: 0, daily: 1, monthly: 2 }

  validates :weekdays, presence: true
  validates :start_time, presence: true
  validates :starts_on, :ends_on, presence: true
  validate :activity_belongs_to_company
  validate :ends_after_starts
  validate :weekdays_are_valid

  scope :active, -> { where(active: true) }

  def generation_end_date
    [ ends_on, Date.current + GENERATION_HORIZON ].min
  end

  # Puts this schedule's sessions on the calendar, up to its horizon.
  # Idempotent: a date that already has its session is skipped. A clash (the
  # coach is elsewhere) is reported rather than raised, so one bad date does
  # not stop the rest. Returns { generated:, skipped:, conflicts: }.
  def generate_sessions!
    result = { generated: 0, skipped: 0, conflicts: [] }
    existing_starts_ats = sessions.pluck(:starts_at).to_set(&:to_i)
    zone = company.time_zone
    last = Time.use_zone(zone) { generation_end_date }

    (starts_on..last).each do |date|
      next unless occurs_on?(date)

      # 18:00 is 18:00 at the gym. This used to build the time in UTC, so
      # every generated class landed an hour late in Tunis — while a
      # one-off session from the calendar, converted by the browser, was
      # right.
      starts_at = zone.local(date.year, date.month, date.day, start_time.hour, start_time.min)

      if existing_starts_ats.include?(starts_at.to_i)
        result[:skipped] += 1
        next
      end

      session = Session.new(
        activity_id: activity_id, company_id: company_id, coach_id: coach_id, recurring_schedule_id: id,
        starts_at: starts_at, ends_at: starts_at + activity.duration.minutes,
        capacity: activity.capacity, status: :scheduled
      )

      if session.save
        result[:generated] += 1
      else
        result[:conflicts] << { starts_at: starts_at, error: session.errors.full_messages.first }
      end
    end

    result
  end

  # Ending a weekly class. No new sessions are generated, and the ones
  # already on the calendar ahead of today are taken off — except any a
  # member has booked or queued for, which stay for the gym to handle one by
  # one rather than being cancelled under someone's feet. Returns
  # { cancelled_sessions:, kept_sessions: }.
  def stop!
    result = { cancelled_sessions: 0, kept_sessions: 0 }

    transaction do
      update!(active: false)

      sessions.scheduled.where(starts_at: Time.current..).find_each do |session|
        if session.bookings.where(status: %i[confirmed waitlisted]).exists?
          result[:kept_sessions] += 1
        else
          session.cancel!
          result[:cancelled_sessions] += 1
        end
      end
    end

    result
  end

  private

  def occurs_on?(date)
    case recurrence_type
    when "weekly" then weekdays.include?(date.wday)
    when "daily" then true
    when "monthly" then date.day == starts_on.day
    end
  end

  # A recurring slot can only run an activity its own gym offers.
  def activity_belongs_to_company
    return if activity.blank? || company.blank?

    errors.add(:activity, "must belong to this gym") if activity.company != company
  end

  def ends_after_starts
    return if starts_on.blank? || ends_on.blank?

    errors.add(:ends_on, "must be after the start date") if ends_on < starts_on
  end

  def weekdays_are_valid
    return if weekdays.blank?

    errors.add(:weekdays, "must be between 0 (Sunday) and 6 (Saturday)") unless weekdays.all? { |d| (0..6).cover?(d) }
  end
end
