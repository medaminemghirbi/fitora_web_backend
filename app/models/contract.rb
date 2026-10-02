class Contract < ApplicationRecord
  belongs_to :client
  belongs_to :contract_type
  # What this contract books — OPTIONAL, and the absence carries meaning:
  #
  #   activity present → this contract is for that one activity
  #   activity NULL    → this contract covers every activity its plan covers
  #
  # That second case is how an "all-access" membership is sold. Both are read
  # through #covers_activity?; never compare activity_id directly.
  belongs_to :activity, optional: true
  belongs_to :company
  belongs_to :created_by, class_name: "User", optional: true

  has_many :contract_periods, dependent: :destroy
  has_many :payments, through: :contract_periods
  has_many :bookings, through: :contract_periods

  # Scoped by activity too: the same client can hold the same plan more than
  # once as long as each contract is for a different activity. Two
  # all-access contracts on one plan (both activity_id NULL) still collide,
  # which is right — that is the same membership sold twice.
  validates :client_id, uniqueness: { scope: [ :contract_type_id, :activity_id ] }

  # Every reasoning about "the client's contract" (status, dates, price,
  # remaining sessions) is really about their CURRENT term — the period in
  # force today — so it's delegated rather than stored flat on Contract
  # itself.
  # Not memoized: #reload doesn't know to clear a plain ivar, and this
  # isn't a hot enough path to be worth the staleness risk.
  # Everything ContractSerializer reads, loaded once for a whole list.
  # `preload` for the periods, never `includes`: see #periods_by_time.
  scope :for_serializer, -> {
    preload(:contract_periods, :activity, :client, contract_type: { contract_type_activities: :activity })
  }

  delegate :status, :starts_at, :expires_at, :remaining_bookings, :discount, :final_price, :payment_status,
           :pending?, :active?, :expired?, :cancelled?, :unpaid?, :paid?,
           to: :current_period, allow_nil: true

  # Sells a client a plan for an activity, optionally taking the money in
  # the same transaction, and returns the new ContractPeriod (its #contract
  # and, when collected, its #payments).
  #
  # One Contract per (client, plan, activity): a second purchase of the same
  # plan for the same activity is a new period under the same contract, not
  # a new contract; a different activity under the same plan is a genuinely
  # separate contract.
  def self.sell!(client:, contract_type:, activity:, created_by:, starts_on: Date.current, discount: 0,
                 collect_payment: false, payment_method: nil, payment_notes: nil)
    # The price is the gym's, never the caller's: it's read from the plan's
    # pricing grid for this activity and frozen onto the period below, so a
    # client can't be subscribed at a price the frontend made up.
    base_price = contract_type.price_for(activity)
    if base_price.nil?
      # Says what to do, not only what is wrong: whoever hits this is at a
      # desk with someone waiting, and the fix is two screens away.
      raise Refused, "\"#{contract_type.name}\" has no price for #{activity.name}. " \
                     "Set one in Abonnements → Formules before selling it."
    end

    transaction do
      # Date#to_time would resolve "starts_on" in the system's local
      # timezone rather than Time.zone, silently shifting the date by a day
      # whenever they differ — in_time_zone is the zone-aware conversion.
      starts_at = starts_on.in_time_zone

      contract = find_or_create_by!(client: client, contract_type: contract_type, activity: activity) do |c|
        c.company = contract_type.company
        c.created_by = created_by
      end

      period = contract.contract_periods.create!(
        status: :active,
        starts_at: starts_at,
        expires_at: starts_at + contract_type.duration_days.days,
        remaining_bookings: contract_type.unlimited_bookings? ? nil : contract_type.booking_limit,
        discount: discount,
        base_price: base_price
      )

      # No part payments: collecting on creation records the full price.
      if ActiveModel::Type::Boolean.new.cast(collect_payment)
        Payment.create!(
          client: client,
          company: contract_type.company,
          contract_period: period,
          amount: period.final_price,
          currency: contract_type.currency,
          payment_method: Payment::SELECTABLE_METHODS.include?(payment_method.to_s) ? payment_method : :cash,
          status: :paid,
          paid_at: Time.current,
          notes: payment_notes,
          created_by: created_by
        )
        period.update!(payment_status: :paid)
      end

      period
    end
  end

  # Adds a new period under this SAME contract — the client's renewal
  # history stays linked instead of scattering into disconnected rows, while
  # every existing period is left exactly as it was ("never touch contract
  # history"). Returns the new period.
  def renew!
    plan = contract_type
    current = current_period

    # Queues behind EVERYTHING already sold, not merely behind the current
    # term: renew twice in a row and the second period starts where the
    # first one ends. A term still running is left untouched and keeps its
    # dates, its price and its remaining sessions until its last day — the
    # renewal simply waits its turn (#current_period).
    starts_at = [ covered_through, Time.current ].compact.max

    # A renewal is a new sale, so it takes today's tariff for this
    # activity — the previous period keeps whatever it was sold at. Falls
    # back to that older price if the grid row has since been removed.
    base_price = plan.price_for(activity) || current&.base_price || 0

    contract_periods.create!(
      status: :active,
      starts_at: starts_at,
      expires_at: starts_at + plan.duration_days.days,
      remaining_bookings: plan.unlimited_bookings? ? nil : plan.booking_limit,
      discount: current&.discount || 0,
      base_price: base_price
    )
  end

  # Edits the CURRENT period — start date, end date and (while still unpaid)
  # the discount. Changing the start date re-derives the end date from the
  # plan's billing period unless an explicit end date is given.
  def update_current_period!(starts_on: nil, expires_on: nil, discount: nil)
    period = current_period
    raise Refused, "No active subscription to edit" if period.nil?
    raise Refused, "This subscription can no longer be edited" unless period.active? || period.pending?

    attrs = {}

    if starts_on.present?
      starts_at = Date.parse(starts_on.to_s).in_time_zone
      attrs[:starts_at] = starts_at
      attrs[:expires_at] = starts_at + contract_type.duration_days.days
    end

    attrs[:expires_at] = Date.parse(expires_on.to_s).in_time_zone if expires_on.present?

    if discount.present?
      raise Refused, "Discount can only change while the subscription is unpaid" unless period.unpaid?

      attrs[:discount] = discount.to_f
    end

    period.update!(attrs) if attrs.any?
  rescue ArgumentError
    raise Refused, "Invalid date"
  end

  def cancel!
    raise Refused, "This contract is already cancelled." if cancelled?

    current_period.update!(status: :cancelled)
  end

  # The period IN FORCE TODAY — the latest one that has already started,
  # not simply the latest one on file. The difference is the whole point of
  # renewing early: a renewal queued while the running term still has weeks
  # left is a FUTURE period, and reading it as "current" would hide the term
  # the member is actually living under (its dates, its price, its remaining
  # sessions) behind one that hasn't begun. Both are kept; only one is
  # current. Before anything has started — a contract sold to start next
  # month — the nearest upcoming period stands in, so the contract is never
  # period-less.
  def current_period
    started, upcoming = periods_by_time
    started.last || upcoming.first
  end

  # The renewals waiting behind the current term, soonest first. Never
  # touched by the everyday reads above: they exist to be SHOWN, so nobody
  # sells the same month twice.
  def upcoming_periods
    _started, upcoming = periods_by_time
    upcoming
  end

  def next_period
    upcoming_periods.first
  end

  # Everything still owed on this contract: the current term plus any
  # renewal queued behind it. A renewal is sold unpaid, and since it is no
  # longer the current period, reading the current one alone would make the
  # money the gym is owed for it disappear from the desk's screens.
  def unpaid_periods
    started, upcoming = periods_by_time
    ([ started.last ] + upcoming).compact.reject(&:cancelled?).select(&:unpaid?)
  end

  # What "Encaisser" settles: the oldest thing still owed, so a queued
  # renewal is collected once the current term has been.
  def payable_period
    unpaid_periods.first
  end

  def amount_due
    unpaid_periods.sum { |p| p.final_price.to_f }
  end

  # The end of everything already sold — where a renewal has to start so it
  # queues behind the current term instead of overlapping it, including when
  # a renewal is queued behind an earlier renewal. A cancelled period sold
  # nothing, so re-subscribing after a cancellation starts today rather than
  # at the end of the term that was given up.
  def covered_through
    contract_periods.reject(&:cancelled?).filter_map(&:expires_at).max
  end

  # `period:` lets a caller re-check eligibility against an already-locked
  # ContractPeriod row instead of the unlocked current_period lookup — see
  # Session#book!, which re-verifies through a `SELECT ... FOR UPDATE`
  # row after picking a candidate contract, closing the check-then-act
  # window a concurrent booking against the same contract could otherwise
  # slip through (same class of race the Session capacity lock exists for).
  def usable_for?(activity:, period: current_period)
    return false unless period&.active? && (period.expires_at.nil? || period.expires_at >= Time.current)
    return false if contract_type.booking_limit.present? && !contract_type.unlimited_bookings? && period.remaining_bookings.to_i <= 0
    covers_activity?(activity)
  end

  # Does this contract let the member into this activity?
  #
  # A contract pinned to one activity answers on that alone. An all-access
  # contract (activity_id NULL) defers to its plan, which is the only place
  # the answer lives. Either way the plan has the final say: an activity
  # dropped from the plan stops being covered by contracts sold under it.
  def covers_activity?(activity)
    return false if activity.blank?
    return false unless contract_type.grants_access_to?(activity: activity)

    activity_id.nil? || activity_id == activity.id
  end

  # True for the "covers everything on the plan" kind.
  def all_access?
    activity_id.nil?
  end

  # The activities this contract can actually book, for display.
  def covered_activities
    all_access? ? contract_type.activities : [ activity ].compact
  end

  # What this contract is for, in words — the one activity it names, or the
  # names of everything its plan covers. Never nil: an all-access contract
  # has no `activity` to call `.name` on, and every caller that used to
  # assume one is reading this instead.
  def activity_label
    return activity.name if activity
    # From the plan's pricing rows, so a list that preloaded them asks the
    # database nothing more here.
    names = contract_type.contract_type_activities.map { |row| row.activity.name }.sort
    return names.to_sentence if names.any?

    "—"
  end

  def consume_booking!(period: current_period)
    return if contract_type.unlimited_bookings?
    return if period&.remaining_bookings.nil?

    period.decrement!(:remaining_bookings)
  end

  def restore_booking!
    return if contract_type.unlimited_bookings?
    return if current_period&.remaining_bookings.nil?

    current_period.increment!(:remaining_bookings)
  end

  private

  # Splits the contract's periods in two at "now", each side in chronological
  # order. Sorted in Ruby rather than SQL so a preloaded association is read
  # from memory (the contracts list preloads :contract_periods and asks every
  # row for its current period) — which means a caller must PRELOAD the
  # periods, never `includes` them alongside a filter on contract_periods:
  # that collapses into one join and leaves the association holding only the
  # matching rows, and this would then answer about the wrong period. A period with no start date counts as
  # started — it was written before dates were required, and pretending it
  # lies in the future would hide it forever.
  def periods_by_time
    now = Time.current
    sorted = contract_periods.to_a.sort_by { |p| [ p.starts_at || p.created_at, p.created_at ] }
    sorted.partition { |p| (p.starts_at || p.created_at) <= now }
  end
end
