# The admin's page about their account's Fitora access: whether it is open
# and until when, every invoice, which plan it is on, what both plans cost in
# its currency, and where to send the money.
class SubscriptionStatusSerializer
  def initialize(company:, admin:)
    @company = company
    @admin = admin
  end

  def as_json(*)
    subscription = admin.subscription
    currency = subscription&.currency || company&.currency

    {
      subscription: SubscriptionSerializer.new(subscription).as_json,
      invoices: subscription ? subscription.invoices.newest_first.map { |i| InvoiceSerializer.new(i).as_json } : [],
      # The account's usage, across every salle the plan covers.
      companies_count: admin.companies.count,
      clients_used: admin.salle_memberships.distinct.count(:client_id),
      staff_used: admin.salle_staff_members.distinct.count(:user_id),
      currency: currency,
      currency_symbol: currency && CurrencyCatalog.symbol(currency),
      monthly_subscription_cents: subscription&.monthly_cents || 0,
      annual_subscription_cents: subscription&.annual_cents || 0,
      annual_discount_percent: PlatformSetting.current.annual_discount_percent,
      arrears_cents: subscription&.arrears_cents || 0,
      trial_days: Subscription::TRIAL_DAYS,
      included_modules: ModuleCatalog::KEYS,
      # Both plans, priced in the account's currency — the full comparison,
      # not just the one it is on.
      plans: plans(currency),
      # Where to send the money. nil when no RIB is configured, and the page
      # falls back to the generic wording.
      payout: PayoutAccount.current&.as_json(company: subscription&.billing_company || company)
    }
  end

  private

  attr_reader :company, :admin

  def plans(currency)
    return [] if currency.blank?

    SubscriptionPrice::PLANS.map do |plan|
      price = SubscriptionPrice.for(currency, plan: plan)
      { key: plan, monthly_cents: price.monthly_cents, annual_cents: price.annual_cents }
    end
  end
end
