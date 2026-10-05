module Notifications
  # Every quarter of an hour: reminds members of a session coming up within
  # their gym's `booking.reminder_hours`. A one-to-one slot nobody turns up
  # to is an hour a studio cannot sell again; this is what keeps that rare.
  #
  # Each booking is reminded once (bookings.reminder_sent_at), on the
  # member's app and — when the gym pays for it — by SMS. Someone who booked
  # inside the window already knows, so they are left alone.
  class SendSessionRemindersJob < ApplicationJob
    queue_as :default

    # The furthest ahead any gym may ask for (CompanySettings BOOKING).
    LOOKAHEAD = CompanySettings::BOOKING[:reminder_hours][:max].hours

    def perform
      now = Time.current
      due = Booking.confirmed.where(reminder_sent_at: nil)
                   .joins(:session).merge(Session.scheduled)
                   .where(sessions: { starts_at: now..(now + LOOKAHEAD) })
                   .includes(:client, session: [ :activity, :company ])

      due.find_each do |booking|
        session = booking.session
        hours = session.company.settings.reminder_hours
        next if hours.zero?
        next if session.starts_at > now + hours.hours
        # Booked inside the window: they have only just chosen it.
        next if booking.created_at > session.starts_at - hours.hours

        remind(booking)
      end
    end

    private

    def remind(booking)
      session = booking.session
      company = session.company

      Notification.push(
        recipient: booking.client, company: company, kind: "session_reminder", subject: booking,
        dedup_key: "session_reminder:#{booking.id}", url: "/member/bookings",
        data: { activity_name: session.activity.name, starts_at: session.starts_at.iso8601, gym_name: company.name }
      )
      send_sms(booking) if company.settings.reminder_sms?
      booking.update_columns(reminder_sent_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    # Best effort: a member with no usable number, or a gateway that is
    # down, must not stop everyone else's reminder — nor be retried every
    # fifteen minutes.
    def send_sms(booking)
      booking.send_reminder!
    rescue ApplicationRecord::Refused => e
      Rails.logger.info("[reminders] SMS not sent for booking #{booking.id}: #{e.message}")
    end
  end
end
