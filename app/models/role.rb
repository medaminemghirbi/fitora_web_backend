# A company-scoped, editable set of permissions that staff logins are
# assigned to. Every company starts with three built-in roles seeded from
# DEFAULTS — the admin (key `admin`), the moderator and the coach; the admin
# can rename them, change their permissions (except the admin's own), or add
# custom roles ("Comptable", "Assistant·e", …) via the roles editor.
#
# The built-in roles keep their `key` (SYSTEM_KEYS) so the backend and
# frontend still recognise them; a custom role gets a `key` slugified from
# its name, fixed at creation.
class Role < ApplicationRecord
  belongs_to :company
  has_many :staff_members, foreign_key: :role_id, inverse_of: :assigned_role, dependent: :restrict_with_error

  SYSTEM_KEYS = %w[admin moderator coach].freeze

  DEFAULTS = {
    # The gym's admin, "Administrateur" on screen. (Fitora's own operator is
    # the superadmin, User#superadmin?, and has no role here.)
    "admin" => {
      name: "Administrateur",
      permissions: Permission::ALL
    },
    # The back office: runs the gym day to day — members, coaches, the
    # schedule, the desk, the money taken at it. Not the catalogues
    # (activities, plans), the settings, the roles or other staff logins:
    # those stay the admin's, and so does who becomes a moderator.
    #
    # "payments" without "revenue" is the distinction that matters: taking
    # money at the desk is the job, reading what the gym earns is not.
    "moderator" => {
      name: "Modérateur",
      permissions: %w[sessions bookings clients contracts payments checkin reports coaches]
    },
    "coach" => {
      name: "Coach",
      permissions: %w[checkin]
    }
  }.freeze

  before_validation :normalise

  validates :key, presence: true, uniqueness: { scope: :company_id, case_sensitive: false }
  validates :name, presence: true

  scope :ordered, -> { order(:position, :name) }

  # A built-in role can be re-permissioned and renamed but not deleted or
  # re-keyed; a custom role can be deleted once nothing is assigned to it.
  def builtin?
    self[:builtin]
  end

  def deletable?
    !builtin? && staff_members.none?
  end

  def self.seed_defaults_for(company)
    DEFAULTS.each_with_index do |(key, attrs), index|
      role = company.roles.find_or_initialize_by(key: key)
      if role.new_record?
        role.name = attrs[:name]
        role.permissions = attrs[:permissions]
      end
      role.builtin = true
      role.position = index
      role.save!
    end
  end

  private

  def normalise
    self.permissions = Permission.sanitize(permissions)
    # A custom role has no key on create — slugify it from the name, once.
    self.key = (key.presence || name).to_s.strip.parameterize(separator: "_").presence
  end
end
