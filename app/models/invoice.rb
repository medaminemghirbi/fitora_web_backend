# One period of Gymly access, paid for and recorded.
#
# Payment happens off-app, so an invoice is not a demand — it is the proof
# that money arrived. A Gymly superadmin confirms it, the invoice is issued, and
# it lands in the admin's account to download. It covers the account — every
# salle the admin runs — not one gym.
#
# Everything about the subscription that used to be stored is read from
# these: "paid until" is the latest period_end, arrears are the periods
# without a row.
class Invoice < ApplicationRecord
  belongs_to :subscription
  belongs_to :issued_by, class_name: "User", optional: true

  enum :billing_period, Subscription::BILLING_PERIODS, prefix: :covers
  # The plan this period was bought on, frozen at issue like the amount.
  attribute :plan, :string
  enum :plan, Subscription::PLANS, prefix: :on, validate: true

  validates :number, presence: true, uniqueness: true
  validates :period_start, :period_end, :issued_at, presence: true
  validates :amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :currency, presence: true
  validate :period_runs_forwards

  delegate :admin, :billing_company, to: :subscription

  scope :chronological, -> { order(:period_start) }
  scope :newest_first, -> { order(period_start: :desc) }
  scope :covering, ->(date) { where(period_start: ..date).where(period_end: date..) }

  def amount
    amount_cents / 100.0
  end

  def covers?(date)
    (period_start..period_end).cover?(date)
  end

  # FIT-2026-0042: the year it was issued in, then a counter within that
  # year, from one counter row per year (invoice_sequences). Atomic under
  # concurrent callers,
  # and inside the caller's transaction, so a rolled-back invoice does not
  # leave a gap.
  def self.next_number(now: Time.current)
    year = now.year
    sequence = connection.select_value(sanitize_sql_array([ <<~SQL, year ]))
      INSERT INTO invoice_sequences (year, last_value) VALUES (?, 1)
      ON CONFLICT (year) DO UPDATE SET last_value = invoice_sequences.last_value + 1
      RETURNING last_value
    SQL
    format("FIT-%<year>d-%<sequence>04d", year: year, sequence: sequence)
  end

  private

  def period_runs_forwards
    return if period_start.blank? || period_end.blank?
    return if period_end >= period_start

    errors.add(:period_end, "must not be before the period starts")
  end
end
