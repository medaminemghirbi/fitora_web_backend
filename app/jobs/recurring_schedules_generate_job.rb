# Keeps every active recurring schedule's 90-day window topped up, so a
# weekly class keeps appearing on the calendar as the weeks go by. Scheduled
# nightly in config/sidekiq_cron.yml.
#
# Idempotent — RecurringSchedule#generate_sessions! skips any date that already has a
# session, so a missed night, or two runs, change nothing.
class RecurringSchedulesGenerateJob < ApplicationJob
  queue_as :default

  def perform
    RecurringSchedule.active.includes(:company).where("ends_on >= ?", Date.current).find_each do |schedule|
      schedule.generate_sessions!
    end
  end
end
