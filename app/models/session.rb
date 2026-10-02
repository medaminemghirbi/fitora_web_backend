class Session < ApplicationRecord
  belongs_to :activity
  belongs_to :company
  belongs_to :coach, optional: true
  belongs_to :recurring_schedule, optional: true
  # Optional twice over: a company may not use rooms at all
  # (CompanySettings FEATURES[:spaces]), and a company that does may still
  # leave a session unassigned while the schedule is being drafted.
  belongs_to :space, optional: true

  has_many :bookings, dependent: :destroy

  enum :status, { scheduled: 0, cancelled: 1, completed: 2 }

  # The GiST exclusion constraint that keeps a coach out of two places at
  # once. The database is the real guard; #explain_coach_overlap only turns
  # its refusal into an error on the form rather than a 500.
  COACH_OVERLAP_CONSTRAINT = "no_overlapping_coach_sessions".freeze

  around_save :explain_coach_overlap

  validates :starts_at, :ends_at, :capacity, presence: true
  validates :capacity, numericality: { greater_than: 0 }
  validates :price, numericality: { greater_than_or_equal_to: 0 }
  validate :activity_belongs_to_company
  validate :coach_belongs_to_company
  validate :space_belongs_to_company
  validate :space_can_host_activity
  validate :capacity_fits_in_space
  validate :ends_after_starts

  scope :upcoming, -> { where("starts_at >= ?", Time.current) }
  scope :for_date, ->(date) { where(starts_at: date.all_day) }

  def confirmed_bookings_count
    bookings.confirmed.count
  end

  # Confirmed + awaiting-payment bookings both hold a capacity slot, so a
  # session can't be oversold while a pay-per-booking checkout is in flight.
  def held_bookings_count
    bookings.held.count
  end

  def full?
    held_bookings_count >= capacity
  end

  # Books a member in, and returns the booking.
  #
  # `by:` says who is asking. A member booking from their own app is held to
  # the gym's rules about self-booking and how far ahead the schedule opens;
  # the desk is not — staff booking on someone's behalf is the escape hatch
  # for every case the rules did not anticipate.
  #
  # When the session is full and the gym runs a queue, the booking is a
  # place in line (waitlisted), not a seat.
  def book!(client, by: :staff)
    transaction do
      # The lock queues a concurrent booking behind this one, so two people
      # can never both take the last seat.
      lock!
      gym = activity.company

      raise Refused, "This session has been cancelled." if cancelled?
      raise Refused, "This session is no longer available." if starts_at < Time.current
      if by == :member && (refusal = member_booking_refusal(gym))
        raise Refused, refusal
      end
      if bookings.where(client_id: client.id).where.not(status: :cancelled).exists?
        raise Refused, "This client already has a booking for this session."
      end
      # No queue here: a full session is simply full, and saying so is more
      # use than telling them about a contract they would also need.
      raise Refused, "This session is full." if full? && !gym.feature?(:waitlist)

      contract = contract_covering(client, gym)
      period = contract && contract.contract_periods.lock.find(contract.current_period.id)
      unless contract&.usable_for?(activity: activity, period: period)
        raise Refused, "This client needs an active contract to book this activity."
      end

      # Full, but this gym runs a queue — and a queue is still only for
      # members entitled to be in the session at all.
      full? ? join_waitlist!(client, period) : take_seat!(client, contract, period)
    end
  rescue ActiveRecord::RecordNotUnique
    raise Refused, "This client already has a booking for this session."
  end

  # A seat has come free: give it to whoever has waited longest. Returns the
  # booking that was promoted, or nil when nobody was waiting, there was no
  # room for them, or the gym runs no waitlist.
  #
  # Only for a gym that turned the waitlist on: a queue nobody works through
  # is worse than a session that is honestly full. Called inside the
  # caller's transaction (Booking#cancel!), and takes the same lock #book!
  # does, so a seat freed while another request is booking cannot be handed
  # out twice.
  def promote_from_waitlist!
    return nil unless company&.feature?(:waitlist)

    lock!
    # Never into a class that has been called off.
    return nil unless scheduled?
    return nil if full?

    next_up = bookings.queued.first
    return nil if next_up.nil?

    next_up.update!(status: :confirmed, waitlist_position: nil)
    next_up.contract_period&.contract&.consume_booking!(period: next_up.contract_period)
    resequence_queue
    # A seat that came free is only worth having if the member knows.
    notify_member(next_up.client, kind: "waitlist_promoted", subject: next_up, dedup_key: "waitlist_promoted:#{next_up.id}")

    next_up
  end

  # Calls the session off, and everything that has to go with it: every
  # seat and queue place on it is cancelled through Booking#cancel!, which
  # gives back what was spent, and each member is told. Staff are cancelling
  # here, not the member, so no cancellation window applies. Returns how many
  # bookings were cancelled.
  def cancel!
    raise Refused, "This session is already cancelled." if cancelled?

    transaction do
      # This very object, locked and cancelled: the bookings below reach
      # their session through it, and must see it called off, or freeing a
      # seat would promote the queue into a class that is not happening.
      lock!
      update!(status: :cancelled)

      # The queue first, so nobody in it is promoted into a seat on the way.
      cancelled = bookings.waitlisted.to_a + bookings.confirmed.to_a
      cancelled.each do |booking|
        booking.cancel!
        notify_member(booking.client, kind: "session_cancelled", subject: self, dedup_key: "session_cancelled:#{id}:#{booking.client.id}")
      end
      cancelled.size
    end
  end

  private

  def explain_coach_overlap
    yield
  rescue ActiveRecord::StatementInvalid => e
    raise unless e.message.include?(COACH_OVERLAP_CONSTRAINT)

    errors.add(:base, "Coach already has a session at that time.")
    raise ActiveRecord::RecordInvalid, self
  end

  # The rules that apply to a member booking themselves in, and to nobody
  # else. nil when they are satisfied.
  def member_booking_refusal(gym)
    settings = gym.settings
    return "Online booking is not available at this gym." unless settings.feature?(:online_booking)

    horizon = settings.booking_opens_days
    if horizon && starts_at > horizon.days.from_now.end_of_day
      return "This session opens for booking #{horizon} days before it starts."
    end

    nil
  end

  def contract_covering(client, gym)
    client.contracts.joins(:contract_periods).merge(ContractPeriod.currently_active)
          .where(company: gym).distinct
          .find { |c| c.usable_for?(activity: activity) }
  end

  def take_seat!(client, contract, period)
    booking = bookings.create!(
      client: client,
      status: :confirmed,
      amount: 0,
      currency: activity.company.currency,
      payment_status: :paid,
      contract_period: period
    )
    contract.consume_booking!(period: period)
    booking
  end

  # A place in the queue, not a seat. No credit is spent: the member is only
  # charged a session if the seat actually comes free
  # (#promote_from_waitlist!).
  def join_waitlist!(client, period)
    last = bookings.queued.maximum(:waitlist_position).to_i

    bookings.create!(
      client: client,
      status: :waitlisted,
      waitlist_position: last + 1,
      amount: 0,
      currency: activity.company.currency,
      payment_status: :unpaid,
      contract_period: period
    )
  end

  # Close the gap a promotion left, so positions stay 1, 2, 3 rather than
  # drifting into 2, 5, 9 as people come and go.
  def resequence_queue
    bookings.queued.each_with_index do |booking, index|
      position = index + 1
      booking.update_columns(waitlist_position: position) if booking.waitlist_position != position # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def notify_member(client, kind:, subject:, dedup_key:)
    Notification.push(
      recipient: client, company: company, kind: kind, subject: subject,
      dedup_key: dedup_key, url: "/member/bookings",
      data: { activity_name: activity.name, starts_at: starts_at.iso8601, gym_name: company.name }
    )
  end

  # A session can only run an activity its own gym offers.
  def activity_belongs_to_company
    return if activity.blank? || company.blank?

    # Compared as objects, not ids: on an unsaved record both ids are nil and
    # an id comparison would call a mismatch a match.
    errors.add(:activity, "must belong to this gym") if activity.company != company
  end

  # The site check this replaced was the only thing stopping another gym's
  # coach being scheduled here; the gym itself is the boundary now.
  def coach_belongs_to_company
    return if coach.blank? || company.blank?

    errors.add(:coach, "must belong to this gym") if coach.company != company
  end

  def ends_after_starts
    return if starts_at.blank? || ends_at.blank?

    errors.add(:ends_at, "must be after the start time") if ends_at <= starts_at
  end

  # Same boundary as the coach check: the gym owns its rooms.
  def space_belongs_to_company
    return if space.blank? || company.blank?

    errors.add(:space, "must belong to this gym") if space.company != company
  end

  # An activity may name the rooms it can run in; most name none, which
  # means anywhere. Only a real restriction is enforced.
  def space_can_host_activity
    return if space.blank? || activity.blank?

    errors.add(:space, "cannot host \"#{activity.name}\"") unless space.hosts?(activity)
  end

  # A room's capacity is how many people fit in it. Booking more seats than
  # the room holds is not something to discover on the day.
  def capacity_fits_in_space
    return if space.blank? || capacity.blank? || space.capacity.blank?

    return if capacity <= space.capacity

    errors.add(:capacity, "is more than #{space.name} holds (#{space.capacity})")
  end
end
