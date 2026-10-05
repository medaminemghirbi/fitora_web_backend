FactoryBot.define do
  factory :pack do
    company
    sequence(:name) { |n| "Pack #{n}" }

    # A pack bundles at least two activities, so one is built with two of
    # the company's own unless the caller names them.
    activities { create_list(:activity, 2, company: company) }
  end

  factory :contract_type_pack do
    contract_type
    pack { create(:pack, company: contract_type.company) }
    price { 120 }
  end
end
