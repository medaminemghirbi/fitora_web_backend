FactoryBot.define do
  factory :subscription do
    # The account's subscription. Specs written when it belonged to a gym
    # still say `create(:subscription, company: company)`: that means the
    # account of that company's admin.
    transient do
      company { nil }
    end

    admin { company&.admin || association(:user, :admin) }
    active { true }
    billing_period { :monthly }
    plan { :starter }

    trait :pro do
      plan { :pro }
    end

    # Access closed. Which of the two reasons it reports depends on whether
    # an invoice covers today — see Subscription#lock_reason.
    trait :closed do
      active { false }
    end

    # The has_one on the admin may already have cached "none" — a later
    # company.subscription must see this one.
    after(:create) { |subscription| subscription.admin.reload }
  end
end
