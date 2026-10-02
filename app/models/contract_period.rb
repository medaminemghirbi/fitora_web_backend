class ContractPeriod < ApplicationRecord
  belongs_to :contract
  has_many :bookings, dependent: :nullify
  has_many :payments, dependent: :nullify

  enum :status, { pending: 0, active: 1, expired: 2, cancelled: 3 }
  enum :payment_status, { unpaid: 0, paid: 1 }

  validates :starts_at, presence: true, if: :active?
  validates :discount, numericality: { greater_than_or_equal_to: 0 }

  before_validation :compute_final_price

  scope :currently_active, -> { active.where("expires_at IS NULL OR expires_at >= ?", Time.current) }
  scope :expiring_soon, ->(within: 7.days) { currently_active.where(expires_at: Time.current..Time.current + within) }

  # Warning window for the admin notification.
  NOTIFY_WITHIN = 14.days

  after_commit :notify_if_expiring, on: [ :create, :update ]

  def expiring_soon?(within: NOTIFY_WITHIN)
    active? && expires_at.present? && expires_at.between?(Time.current, Time.current + within)
  end

  private

  def notify_if_expiring
    return if destroyed? || !expiring_soon?
    return unless saved_change_to_expires_at? || saved_change_to_status? || previously_new_record?

    Notifications::ContractExpiryChangedJob.perform_later(id)
  end

  # base_price is the catalogue price frozen when this period was created
  # (Contract.sell! / Contract#renew!) and is never rewritten — so a
  # later change to the activity's tariff leaves already-sold periods alone.
  # Only the discount, which the admin can still edit while unpaid, moves
  # final_price after the fact.
  def compute_final_price
    return if base_price.blank?

    self.final_price = [ base_price.to_f - discount.to_f, 0 ].max
  end
end
