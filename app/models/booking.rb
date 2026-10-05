class Booking < ApplicationRecord
  belongs_to :client
  belongs_to :session
  belongs_to :contract, optional: true

  has_many :payments, dependent: :nullify
  has_one :attendance_record, dependent: :destroy

  # 4 is the queue. 0..3 were already written into every existing row, so the
  # waitlist takes the next value rather than renumbering an enum in place.
  enum :status, { confirmed: 0, cancelled: 1, completed: 2, no_show: 3, waitlisted: 4 }
  enum :payment_status, { unpaid: 0, paid: 1 }

  # The statuses that occupy a seat. A waitlisted booking deliberately is not
  # one of them — that is the whole point of the queue.
  HELD_STATUSES = %w[confirmed].freeze

  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :currency, presence: true
  validates :client_id, uniqueness: {
                           scope: :session_id,
                           conditions: -> { where(status: HELD_STATUSES) },
                           message: "has already booked this session"
                         },
                         if: -> { HELD_STATUSES.include?(status) }

  validates :waitlist_position, numericality: { greater_than: 0 }, allow_nil: true
  # Mirrors the waitlist_position_iff_waitlisted check constraint, so the
  # failure is a validation error on a form rather than a 500 from Postgres.
  validate :waitlist_position_matches_status

  scope :held, -> { where(status: HELD_STATUSES) }
  scope :queued, -> { waitlisted.order(:waitlist_position) }

  # `by:` says who is asking. A member cancelling from their own app is held
  # to the gym's cancellation window; the gym's own staff are not, because
  # the desk has to be able to fix things (a member who phoned in, a session
  # the coach called off) and a rule that stops them doing that is a rule
  # that gets worked around by deleting rows.
  def cancel!(by: :staff)
    raise Refused, "This booking is already cancelled." if cancelled?
    if by == :member && (message = too_late_to_cancel)
      raise Refused, message
    end

    # Only a seat spends a session. A place in the queue spent nothing
    # (Session#join_waitlist!), so cancelling it gives nothing back — it
    # used to, which handed out a free session per queue exit.
    held_a_seat = confirmed?

    transaction do
      update!(status: :cancelled, waitlist_position: nil)
      if held_a_seat
        contract&.restore_booking!
        # A seat freed in a session that is still on is the next in line's.
        session.promote_from_waitlist! unless session.cancelled?
      end
    end
    self
  end

  # The "Remind client" button: an SMS through Sms::TunisieSmsClient. A
  # missing phone, missing API credentials or a gateway error is refused
  # with the reason, since a staff member triggered this by hand.
  def send_reminder!
    mobile = sms_number(client.phone)
    raise Refused, "Client has no usable phone number" if mobile.blank?

    Sms::TunisieSmsClient.send_message(mobile: mobile, text: reminder_text)
  rescue Sms::TunisieSmsClient::ConfigurationError, Sms::TunisieSmsClient::RequestError => e
    raise Refused, e.message
  end

  private

  # nil when the cancellation is allowed; otherwise what to tell them.
  def too_late_to_cancel
    hours = session&.company&.settings&.cancellation_hours
    return nil if hours.nil? || hours.zero?

    starts_at = session.starts_at
    return nil if starts_at.nil?
    return nil if Time.current <= starts_at - hours.hours

    if Time.current >= starts_at
      "This session has already started."
    else
      "Bookings can only be cancelled up to #{hours} #{'hour'.pluralize(hours)} before the session starts."
    end
  end

  def reminder_text
    "Bonjour #{client.first_name}, rappel : #{session.activity.name} le " \
      "#{session.starts_at.strftime('%d/%m/%Y à %H:%M')} chez #{session.company.name}."
  end

  # TunisieSMS expects a bare digits mobile number prefixed with the
  # country code (e.g. "21620111111") — client phones are stored as
  # entered ("+216 20 111 111", "20 111 111"...), so this strips
  # formatting and fills in Tunisia's 216 prefix when it's missing.
  def sms_number(raw)
    digits = raw.to_s.gsub(/\D/, "").delete_prefix("00")
    return nil if digits.blank?
    return digits if digits.start_with?("216")
    return "216#{digits}" if digits.length == 8

    digits
  end

  def waitlist_position_matches_status
    if waitlisted? && waitlist_position.blank?
      errors.add(:waitlist_position, "is required for a waitlisted booking")
    elsif !waitlisted? && waitlist_position.present?
      errors.add(:waitlist_position, "only applies to a waitlisted booking")
    end
  end
end
