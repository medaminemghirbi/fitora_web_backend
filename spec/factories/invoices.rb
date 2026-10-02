FactoryBot.define do
  factory :invoice do
    # Invoices belong to the account's subscription. `company:` still works:
    # it means that company's account, created on the spot if it has none.
    transient do
      company { nil }
    end

    subscription do
      (company && Subscription.find_by(admin_id: company.admin_id)) ||
        association(:subscription, company: company)
    end
    sequence(:number) { |n| format("FIT-2026-%04d", n) }
    period_start { Date.current.beginning_of_month }
    period_end { Date.current.end_of_month }
    amount_cents { 9_900 }
    plan { :starter }
    currency { "TND" }
    billing_period { :monthly }
    issued_at { Time.current }

    # Covers today and the rest of this month — the ordinary "paid up" case.
    trait :current do
      period_start { Date.current.beginning_of_month }
      period_end { Date.current.end_of_month }
    end

    # Ran out long enough ago that the grace has passed too.
    trait :lapsed do
      period_start { Date.current - 40 }
      period_end { Date.current - 10 }
    end

    # The free days signup gives away — see Companies::Open.
    trait :trial do
      trial { true }
      amount_cents { 0 }
      period_start { Date.current }
      period_end { Date.current + (Subscription::TRIAL_DAYS - 1) }
    end
  end
end
