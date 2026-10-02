# What one plan costs per month in one currency. A company sees its price in
# its own Company#currency (30 TND for a Tunisian gym, 30 EUR for a European
# one), not one fixed platform currency. The year is twelve months less the
# platform-wide annual discount (PlatformSetting). Payment happens outside
# the app — the superadmin just sets the numbers the admin sees.
class SubscriptionPrice < ApplicationRecord
  # The currency every plan is first priced in — a (currency, plan)
  # combination seen for the first time copies its starting price from here
  # (see .for).
  REFERENCE_CURRENCY = "TND"

  PLANS = Subscription::PLANS.values.freeze

  # A starting point only, for a plan never priced anywhere yet; the
  # superadmin reprices each one from there.
  DEFAULT_MONTHLY_CENTS = { "starter" => 16_500, "pro" => 24_900 }.freeze

  validates :currency, presence: true, inclusion: { in: CurrencyCatalog::CODES }
  validates :currency, uniqueness: { scope: :plan }
  validates :plan, inclusion: { in: PLANS }
  validates :monthly_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # The row for a (currency, plan) pair, creating it — seeded from that same
  # plan's REFERENCE_CURRENCY price, or DEFAULT_MONTHLY_CENTS when even that
  # doesn't exist yet — so a newly-seen currency never shows a price gap.
  # An unknown plan reads as Starter rather than raising on bad input.
  def self.for(currency, plan:)
    currency = currency.presence || REFERENCE_CURRENCY
    plan = PLANS.include?(plan.to_s) ? plan.to_s : PLANS.first

    find_or_create_by!(currency: currency, plan: plan) do |row|
      row.monthly_cents = seed_monthly_cents(plan)
    end
  end

  def self.seed_monthly_cents(plan)
    find_by(currency: REFERENCE_CURRENCY, plan: plan)&.monthly_cents || DEFAULT_MONTHLY_CENTS.fetch(plan)
  end
  private_class_method :seed_monthly_cents

  # Twelve months less the annual discount, rounded to the cent.
  def annual_cents(discount = PlatformSetting.current.annual_discount_percent)
    (monthly_cents * 12 * (100 - discount) / 100.0).round
  end
end
