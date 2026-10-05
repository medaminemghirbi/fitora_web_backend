class ContractType < ApplicationRecord
  belongs_to :company

  has_many :contract_type_activities, dependent: :destroy
  has_many :activities, through: :contract_type_activities
  # The packs this formule is sold for, each at its own price — the same
  # grid as the activities above, one row per pack.
  has_many :contract_type_packs, dependent: :destroy
  has_many :packs, through: :contract_type_packs
  has_many :contracts, dependent: :restrict_with_error

  # How long one purchase lasts. A gym sells abonnements by the month,
  # quarter, half-year or year; a studio sells carnets with a lifetime of
  # their own — "10 séances valables 8 semaines" — which is `custom`, with
  # the day count in validity_days. #duration_days reads both.
  enum :billing_period, { monthly: 0, quarterly: 1, semi_annual: 2, yearly: 3, custom: 4 }

  DURATION_DAYS_BY_PERIOD = { "monthly" => 30, "quarterly" => 90, "semi_annual" => 180, "yearly" => 365 }.freeze

  # Price lives per (plan, activity) on contract_type_activities — see
  # #price_for. The plan itself only carries the cadence and booking rules.
  delegate :currency, to: :company

  validates :name, presence: true
  validates :booking_limit, numericality: { greater_than: 0 }, allow_nil: true
  validates :session_count, numericality: { greater_than: 0 }, allow_nil: true
  validates :validity_days, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 730 },
                            allow_nil: true
  validates :validity_days, presence: true, if: :custom?
  validates :color, format: { with: /\A#[0-9a-fA-F]{6}\z/, message: "must be a hex color like #4f46e5" }

  scope :active, -> { where(active: true) }

  # How long one purchase of this plan lasts — computed from billing_period,
  # used by Contract.sell! / #renew! to set expires_at.
  def duration_days
    return validity_days if custom?

    DURATION_DAYS_BY_PERIOD.fetch(billing_period)
  end

  # What this activity costs under this plan, or nil when the plan isn't
  # sold for it at all.
  # What one activity costs on this plan.
  #
  # `nil` asks for the all-access price — a Contract with no activity covers
  # everything the plan covers (see Contract#all_access?), and the dearest
  # covered activity is the floor for that: access to everything cannot
  # sensibly cost less than the most expensive part of it. The admin still
  # sets the actual figure at the point of sale (Contract#final_price);
  # this is the number the sale form starts from.
  # A plan is either unlimited or counted. Holding both — unlimited_bookings
  # with a session_count beside it — is how "24 Séances" came to sell as
  # unlimited: the count named the plan and the flag decided what it did.
  #
  # Normalised rather than rejected: a validation would make every existing
  # row in that state unsaveable, including to fix it.
  before_validation :clear_counts_when_unlimited
  # A fixed period carries its own length; a validity left behind from when
  # the formule was custom would only mislead whoever reads the row.
  before_validation { self.validity_days = nil unless custom? }

  def price_for(activity)
    return contract_type_activities.maximum(:price) if activity.nil?

    contract_type_activities.find_by(activity_id: activity.id)&.price
  end

  # What a pack costs on this formule, or nil when the formule isn't sold
  # for it.
  def price_for_pack(pack)
    contract_type_packs.find_by(pack_id: pack.id)&.price
  end

  # avoids forcing an admin to enumerate them for a simple all-access plan.
  # Activities are different: a plan is only sold for an activity it has a
  # priced row for, so an activity with no row is not covered.
  def grants_access_to?(activity:)
    return false if activity.blank?

    contract_type_activities.exists?(activity_id: activity.id)
  end

  private

  def clear_counts_when_unlimited
    return unless unlimited_bookings?

    self.session_count = nil
    self.booking_limit = nil
  end
end
