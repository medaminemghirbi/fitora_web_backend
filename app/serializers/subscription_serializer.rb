class SubscriptionSerializer
  def initialize(subscription)
    @subscription = subscription
  end

  def as_json(*)
    return nil if subscription.nil?

    {
      id: subscription.id,
      # The access, and nothing else. No date is compared to read it.
      active: subscription.active,
      billing_period: subscription.billing_period,
      # "starter" or "pro" — the account's plan, whichever salle is asking.
      plan: subscription.plan,
      member_app: subscription.member_app?,
      multi_salle: subscription.multi_salle?,
      lock_reason: subscription.lock_reason,
      # What the invoices say, for the screens that show a countdown.
      paid_through: subscription.paid_through,
      current_period_paid: subscription.current_period_paid?,
      days_before_lock: subscription.days_before_lock,
      # Still on the free days (or just past them): nothing paid yet, so no
      # plan chosen yet either.
      trial: subscription.trial?,
      trial_days_left: subscription.trial_days_left
    }
  end

  private

  attr_reader :subscription
end
