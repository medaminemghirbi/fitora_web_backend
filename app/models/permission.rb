# The platform's capability catalogue — the fixed set of things a Role can
# grant. Values are plain strings ("clients", "payments", …); a company's
# Role rows hold a subset of these. Code-defined on purpose: capabilities
# are a property of the platform, not of any one tenant. Roles built from
# them are what's configurable (see Role).
#
# `checked` in a controller via BaseController#require_capability!.
module Permission
  # key => human label (for the settings UI that edits roles).
  CATALOG = {
    "clients"         => "Clients & contacts",
    "activities"      => "Activities",
    "spaces"          => "Rooms",
    "coaches"         => "Team management",
    "sessions"        => "Schedule editing",
    "bookings"        => "Bookings",
    "contracts"       => "Contracts",
    "contract_types"  => "Membership plans",
    "payments"        => "Payments",
    "reports"         => "Dashboard & reports",
    "revenue"         => "Revenue & financial totals",
    "checkin"         => "Attendance check-in"
    # Company settings, staff logins, roles, the subscription and the salles
    # are not here: they are the admin's alone (require_admin!), never
    # something a role can be granted. A "settings" key used to sit here
    # that nothing checked — ticking it gave nothing.
  }.freeze

  ALL = CATALOG.keys.freeze

  def self.valid?(key)
    CATALOG.key?(key.to_s)
  end

  # Keep only recognised keys, de-duplicated, in catalogue order — used to
  # normalise whatever a role edit form submits.
  def self.sanitize(keys)
    given = Array(keys).map(&:to_s)
    ALL.select { |key| given.include?(key) }
  end
end
