module Permissions
  # The single source of truth for "what can this login do" — used by the
  # /me/permissions and /bootstrap endpoints. Every company has every
  # feature, so the admin gets every permission the product exposes; staff
  # get their assigned Role's list; a platform superadmin gets none.
  class Resolve
    Result = Struct.new(:role, :permissions, keyword_init: true)

    def self.call(user:)
      new(user).call
    end

    def initialize(user)
      @user = user
    end

    def call
      return Result.new(role: nil, permissions: []) if user.superadmin?

      company = resolve_company
      available = Permission::ALL

      if user.admin?
        # The admin always has every permission the enabled modules expose —
        # the stored "admin" Role row is cosmetic (its name), so new modules
        # light up for them without re-seeding.
        admin_role = company&.roles&.find_by(key: "admin")
        return Result.new(
          role: role_hash(admin_role) || { key: "admin", name: "Administrateur" },
          permissions: available
        )
      end

      staff_member = user.staff_member
      Result.new(
        role: role_hash(staff_member&.assigned_role) ||
              (staff_member && { key: staff_member.role, name: staff_member.role.to_s.humanize }),
        permissions: (staff_member ? staff_member.permission_keys : []) & available
      )
    end

    private

    attr_reader :user

    def resolve_company
      user.current_company
    end

    def role_hash(role)
      return nil if role.nil?

      { key: role.key, name: role.name }
    end
  end
end
