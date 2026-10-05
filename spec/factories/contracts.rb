FactoryBot.define do
  factory :contract do
    client
    contract_type
    company { contract_type.company }
    # Defaults to the activity the plan is already priced for, so a contract
    # is sellable out of the box; an explicit `activity:` gets a grid row
    # created for it below.
    activity { contract_type.activities.first || create(:activity, company: contract_type.company) }

    status { :active }
    starts_at { 1.day.ago }
    expires_at { 29.days.from_now }
    discount { 0 }
    payment_status { :unpaid }
    remaining_bookings { nil }

    # Priced off the plan's grid, the way Contract.sell! prices it. An
    # all-access contract (activity: nil) has no single grid row — it is
    # priced off the dearest activity the plan covers, the same way
    # ContractType#price_for answers for it.
    base_price do
      if pack
        contract_type.price_for_pack(pack) || 89
      elsif activity
        contract_type.contract_type_activities
                     .find_or_create_by!(activity: activity) { |r| r.price = 89 }.price
      else
        contract_type.price_for(nil) || 89
      end
    end
  end
end
