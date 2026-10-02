# The list of what a Gymly subscription includes.
#
# Every company has every feature — the whole product comes in one
# subscription (see SubscriptionPrice). So this is not an activation or
# billing concept and it decides nothing: it is the key list the admin's
# subscription page renders as "what you get", in display order.
#
# It used to double as the map from a feature to the permissions it unlocks,
# which the permission resolver intersected every role against. That second job
# is gone: permissions are Permission::CATALOG's business, and the duplicate
# list was a bug waiting to happen — "revenue" was missing from it, so it was
# silently stripped from every permission list the API advertised, the
# admin's included.
#
# Display names and descriptions are i18n keys on the frontend
# (`modules.<key>`); nothing here is user-facing text.
#
# Only features with real code behind them belong here. client_portal,
# messaging, pos, maintenance and analytics were removed (no backend or
# frontend anywhere); fleet, inventory and appointments were real but cut by
# the gym-only product decision. suppliers, ged (company_library) and payroll
# (work contracts/leave/absence) were real, implemented features cut by the
# same decision. Re-add a key once its feature exists.
module ModuleCatalog
  BASE_KEY = "base".freeze

  KEYS = %w[clients classes bookings memberships billing hr].freeze

  def self.exists?(key)
    key.to_s == BASE_KEY || KEYS.include?(key.to_s)
  end
end
