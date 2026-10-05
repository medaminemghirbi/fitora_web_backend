# One term of a client's membership: it starts, it ends, it has a price, and
# it is paid or not. Renewing never stretches a contract — it sells a new
# one that points back at the term it follows (renewed_from), whatever
# formule it is for. A member's history is that chain.
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
  # Or a pack — several activities sold as one (see Pack). Never beside an
  # activity: a contract names one thing, or nothing at all (all-access).
  belongs_to :pack, optional: true
  belongs_to :company
  belongs_to :created_by, class_name: "User", optional: true
  # The term this one renews. A renewal is a contract like any other; this
  # is only what links it to the one before.
  belongs_to :renewed_from, class_name: "Contract", optional: true
  has_many :renewals, class_name: "Contract", foreign_key: :renewed_from_id, inverse_of: :renewed_from,
                      dependent: :nullify

  has_many :payments, dependent: :nullify
  has_many :bookings, dependent: :nullify

  enum :status, { pending: 0, active: 1, expired: 2, cancelled: 3 }
  enum :payment_status, { unpaid: 0, paid: 1 }

  validates :starts_at, presence: true, if: :active?
  validates :discount, numericality: { greater_than_or_equal_to: 0 }
  validate :names_an_activity_or_a_pack

  before_validation :compute_final_price
  before_create :assign_invoice_ref
  after_commit :notify_if_expiring, on: [ :create, :update ]

  # Warning window for the admin notification.
  NOTIFY_WITHIN = 14.days
  # How long before its end a term can be renewed. Earlier than that, the
  # desk would be selling a month the member has not reached yet.
  RENEWAL_WINDOW = 10.days

  # Everything ContractSerializer reads, loaded once for a whole list.
  scope :for_serializer, -> {
    preload({ renewals: :contract_type }, :activity, :client, pack: [ :pack_activities, :activities ],
            contract_type: [ { contract_type_activities: :activity }, { contract_type_packs: { pack: :activities } } ])
  }

  scope :currently_active, -> { active.where("contracts.expires_at IS NULL OR contracts.expires_at >= ?", Time.current) }
  # Active and already begun — not a renewal still waiting its turn.
  scope :in_force, -> { currently_active.where("contracts.starts_at IS NULL OR contracts.starts_at <= ?", Time.current) }
  # A paused membership is not running out: its end date moves when it
  # resumes (#resume!), so warning about it would be warning about a date
  # that is not real.
  scope :expiring_soon, ->(within: 7.days) {
    currently_active.where(paused_at: nil).where(expires_at: Time.current..Time.current + within)
  }
  # Not yet followed by anything: no renewal sold behind it, or only one that
  # was cancelled. A term running out or lapsed is work only while this holds.
  scope :not_renewed, -> { where.not(id: Contract.where.not(status: :cancelled).where.not(renewed_from_id: nil).select(:renewed_from_id)) }
  # Not history yet: the term in force and any renewal queued behind it, but
  # not a term whose renewal has already taken over.
  scope :not_superseded, -> {
    where.not(id: Contract.where.not(status: :cancelled).where.not(renewed_from_id: nil)
                          .where("contracts.starts_at IS NULL OR contracts.starts_at <= ?", Time.current)
                          .select(:renewed_from_id))
  }

  # Sells a client a plan for an activity, optionally taking the money in
  # the same transaction, and returns the new Contract (with its #payments
  # when collected).
  def self.sell!(client:, contract_type:, activity:, created_by:, pack: nil, starts_on: Date.current, discount: 0,
                 collect_payment: false, payment_method: nil, payment_notes: nil)
    # A pack stands in for the activity; it is never sold beside one.
    activity = nil if pack

    # The price is the gym's, never the caller's: it's read from the plan's
    # pricing grid for this activity (or pack) and frozen onto the contract
    # below, so a client can't be subscribed at a price the frontend made up.
    base_price = price_of(contract_type, activity: activity, pack: pack)

    transaction do
      # Date#to_time would resolve "starts_on" in the system's local
      # timezone rather than Time.zone, silently shifting the date by a day
      # whenever they differ — in_time_zone is the zone-aware conversion.
      starts_at = starts_on.in_time_zone

      contract = create!(
        client: client, company: contract_type.company, created_by: created_by,
        contract_type: contract_type, activity: activity, pack: pack,
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
          contract: contract,
          amount: contract.final_price,
          currency: contract_type.currency,
          payment_method: Payment::SELECTABLE_METHODS.include?(payment_method.to_s) ? payment_method : :cash,
          status: :paid,
          paid_at: Time.current,
          notes: payment_notes,
          created_by: created_by
        )
        contract.update!(payment_status: :paid)
      end

      contract
    end
  end

  # FAC-2026-0042: the invoice reference printed on the receipt and the
  # signed contract — the year, then a counter for this salle within that
  # year (contract_invoice_sequences). Atomic under concurrent sales, and
  # inside the caller's transaction, so a rolled-back sale leaves no gap.
  def self.next_invoice_ref(company_id, now: Time.current)
    year = now.year
    value = connection.select_value(sanitize_sql_array([ <<~SQL, SecureRandom.uuid, company_id, year ]))
      INSERT INTO contract_invoice_sequences (id, company_id, year, last_value, created_at, updated_at)
      VALUES (?, ?, ?, 1, now(), now())
      ON CONFLICT (company_id, year)
      DO UPDATE SET last_value = contract_invoice_sequences.last_value + 1, updated_at = now()
      RETURNING last_value
    SQL
    format("FAC-%<year>d-%<value>04d", year: year, value: value)
  end

  # What the plan's grid asks for this activity (or pack) today — refusing,
  # in words the desk can act on, when there is no row for it.
  def self.price_of(contract_type, activity:, pack:)
    price = pack ? contract_type.price_for_pack(pack) : contract_type.price_for(activity)
    return price unless price.nil?

    # Says what to do, not only what is wrong: whoever hits this is at a
    # desk with someone waiting, and the fix is two screens away.
    sold = pack ? "the pack #{pack.name}" : (activity&.name || "every activity")
    raise Refused, "\"#{contract_type.name}\" has no price for #{sold}. " \
                   "Set one in Offre → Tarifs before selling it."
  end

  # Sells the term that follows this one and returns it — a new contract,
  # linked back here, never a change to this one ("never touch contract
  # history"). By default it is the same formule for the same activity or
  # pack; pass another and the member moves onto it from the next term.
  #
  # Only the LAST term of a chain renews, and only once it is close to its
  # end (#renewable?). A term still running keeps its dates, its price and
  # its remaining sessions until its last day — the renewal starts where it
  # ends.
  def renew!(contract_type: self.contract_type, activity: self.activity, pack: self.pack, created_by: nil)
    refuse_renewal!
    activity = nil if pack
    same_formule = contract_type == self.contract_type && activity == self.activity && pack == self.pack

    # A renewal is a new sale, so it takes today's tariff. On the same
    # formule it falls back to the price last sold at if the grid row has
    # since been removed; on another formule there is nothing to fall back to.
    tariff = pack ? contract_type.price_for_pack(pack) : contract_type.price_for(activity)
    tariff ||= base_price if same_formule
    tariff ||= self.class.price_of(contract_type, activity: activity, pack: pack)

    # Starts where this term ends — or today, when it already has, or when
    # every session it bought is spent and there is nothing left to wait for.
    starts_at = sessions_used_up? ? Time.current : [ expires_at, Time.current ].compact.max

    # Through the association, so the renewal is visible on this very object
    # (#renewal, #renewable?) without a reload.
    renewals.create!(
      client: client, company: company, created_by: created_by || self.created_by,
      contract_type: contract_type, activity: activity, pack: pack,
      auto_renew: auto_renew,
      status: :active,
      starts_at: starts_at,
      expires_at: starts_at + contract_type.duration_days.days,
      remaining_bookings: contract_type.unlimited_bookings? ? nil : contract_type.booking_limit,
      # A discount was agreed for a formule; it does not follow the member
      # onto another one.
      discount: same_formule ? discount : 0,
      base_price: tariff
    )
  end

  # Edits this term — start date, end date and (while still unpaid) the
  # discount. Changing the start date re-derives the end date from the
  # plan's billing period unless an explicit end date is given.
  def update_term!(starts_on: nil, expires_on: nil, discount: nil)
    raise Refused, "This subscription can no longer be edited" unless active? || pending?

    attrs = {}

    if starts_on.present?
      starts_at = Date.parse(starts_on.to_s).in_time_zone
      attrs[:starts_at] = starts_at
      attrs[:expires_at] = starts_at + contract_type.duration_days.days
    end

    attrs[:expires_at] = Date.parse(expires_on.to_s).in_time_zone if expires_on.present?

    if discount.present?
      raise Refused, "Discount can only change while the subscription is unpaid" unless unpaid?

      attrs[:discount] = discount.to_f
    end

    update!(attrs) if attrs.any?
  rescue ArgumentError
    raise Refused, "Invalid date"
  end

  def cancel!
    raise Refused, "This contract is already cancelled." if cancelled?

    update!(status: :cancelled, paused_at: nil)
  end

  # Puts the membership on hold — an injury, a pregnancy, a month away.
  # Nothing can be booked against it while it is paused, and the time it
  # spends paused is given back on #resume!. Bookings already made are left
  # alone: the desk cancels the ones that should go, one by one.
  def pause!
    raise Refused, "No active subscription to pause." unless active?
    raise Refused, "This subscription is already paused." if paused?
    raise Refused, "This subscription has already ended." if expires_at.present? && expires_at < Time.current

    update!(paused_at: Time.current)
    self
  end

  # Ends the hold and pushes the end date back by however long it lasted.
  # Renewals queued behind this term move by the same amount, so they still
  # start where it now ends instead of overlapping it.
  def resume!
    raise Refused, "This subscription is not paused." unless paused?

    held = Time.current - paused_at
    transaction do
      queued_renewals.each do |queued|
        queued.update!(starts_at: queued.starts_at && queued.starts_at + held,
                       expires_at: queued.expires_at && queued.expires_at + held)
      end
      update!(paused_at: nil, expires_at: expires_at && expires_at + held)
    end
    self
  end

  def paused?
    paused_at.present?
  end

  # Whether "Renouveler" applies to this term: it is the last one on its
  # chain (nothing sold after it), it was not cancelled, and it ends within
  # RENEWAL_WINDOW — or has already ended, or has used every session it
  # bought (a carnet spent in three weeks needs the next one now, not ten
  # days before a date it will never use).
  def renewable?
    renewal_refusal.nil?
  end

  def expiring_soon?(within: NOTIFY_WITHIN)
    active? && !paused? && expires_at.present? && expires_at.between?(Time.current, Time.current + within)
  end

  # The term sold to follow this one, if it still stands.
  def renewal
    renewals.reject(&:cancelled?).min_by { |c| [ c.starts_at || c.created_at, c.created_at ] }
  end

  # The renewals waiting behind this term, in order — the next one, the one
  # after that, and so on down the chain.
  def queued_renewals
    chain = []
    cursor = renewal
    while cursor
      chain << cursor
      cursor = cursor.renewal
    end
    chain
  end

  # No part payments — a term is owed in full or not at all.
  def amount_due
    unpaid? && !cancelled? ? final_price.to_f : 0.0
  end

  def usable_for?(activity:)
    return false unless active? && (expires_at.nil? || expires_at >= Time.current)
    return false if paused?
    return false if contract_type.booking_limit.present? && !contract_type.unlimited_bookings? && remaining_bookings.to_i <= 0
    covers_activity?(activity)
  end

  # Does this contract let the member into this activity?
  #
  # A contract pinned to one activity answers on that alone. An all-access
  # contract (activity_id NULL) defers to its plan, which is the only place
  # the answer lives. Either way the plan has the final say: an activity
  # dropped from the plan stops being covered by contracts sold under it.
  #
  # A pack contract answers on the pack: the formule has to still be sold for
  # the pack, and the pack has to hold the activity. The formule's own
  # per-activity rows don't come into it — a formule may sell only packs.
  def covers_activity?(activity)
    return false if activity.blank?
    return contract_type.price_for_pack(pack).present? && pack.covers?(activity) if pack

    return false unless contract_type.grants_access_to?(activity: activity)

    activity_id.nil? || activity_id == activity.id
  end

  # True for the "covers everything on the plan" kind.
  def all_access?
    activity_id.nil? && pack_id.nil?
  end

  # The activities this contract can actually book, for display.
  def covered_activities
    return pack.activities if pack

    all_access? ? contract_type.activities : [ activity ].compact
  end

  # What this contract is for, in words — the one activity it names, or the
  # names of everything its plan covers. Never nil: an all-access contract
  # has no `activity` to call `.name` on, and every caller that used to
  # assume one is reading this instead.
  def activity_label
    return activity.name if activity
    return "#{pack.name} (#{pack.activity_names.join(', ')})" if pack
    # From the plan's pricing rows, so a list that preloaded them asks the
    # database nothing more here.
    names = contract_type.contract_type_activities.map { |row| row.activity.name }.sort
    return names.to_sentence if names.any?

    "—"
  end

  def consume_booking!
    return if contract_type.unlimited_bookings?
    return if remaining_bookings.nil?

    decrement!(:remaining_bookings)
  end

  def restore_booking!
    return if contract_type.unlimited_bookings?
    return if remaining_bookings.nil?

    increment!(:remaining_bookings)
  end

  private

  def refuse_renewal!
    reason = renewal_refusal
    raise Refused, reason if reason
  end

  # Why this term cannot be renewed, or nil when it can.
  def renewal_refusal
    return "Only an active or expired subscription can be renewed." unless active? || expired?
    return "This subscription has already been renewed — renew the latest term instead." if renewal
    return nil if sessions_used_up?
    return nil if expires_at.present? && expires_at <= RENEWAL_WINDOW.from_now

    "This subscription can be renewed from #{RENEWAL_WINDOW.in_days.to_i} days before it ends."
  end

  def sessions_used_up?
    !contract_type.unlimited_bookings? && !remaining_bookings.nil? && remaining_bookings <= 0
  end

  def assign_invoice_ref
    self.invoice_ref ||= self.class.next_invoice_ref(company_id)
  end

  def names_an_activity_or_a_pack
    errors.add(:pack, "cannot be sold beside an activity") if activity_id.present? && pack_id.present?
  end

  # base_price is the catalogue price frozen when this contract was sold
  # (Contract.sell! / #renew!) and is never rewritten — so a later change to
  # the activity's tariff leaves already-sold contracts alone. Only the
  # discount, which the admin can still edit while unpaid, moves final_price
  # after the fact.
  def compute_final_price
    return if base_price.blank?

    self.final_price = [ base_price.to_f - discount.to_f, 0 ].max
  end

  def notify_if_expiring
    return if destroyed? || !expiring_soon?
    return unless saved_change_to_expires_at? || saved_change_to_status? || previously_new_record?

    Notifications::ContractExpiryChangedJob.perform_later(id)
  end
end
