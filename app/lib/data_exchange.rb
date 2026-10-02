# CSV import/export for the four entities an admin most often needs to move
# in bulk. The key in the URL picks the strategy, and the capability that
# gates it is the one that gates managing that entity elsewhere.
module DataExchange
  REGISTRY = {
    "clients" => DataExchange::Clients,
    "activities" => DataExchange::Activities,
    "contracts" => DataExchange::Contracts,
    "payments" => DataExchange::Payments
  }.freeze
end
