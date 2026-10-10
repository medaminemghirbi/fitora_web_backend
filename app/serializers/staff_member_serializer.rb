class StaffMemberSerializer
  def initialize(staff_member)
    @staff_member = staff_member
  end

  def as_json(*)
    {
      id: staff_member.id,
      role_key: staff_member.role_key,
      role_name: staff_member.assigned_role.name,
      # Whether this login coaches — a different question from what its role
      # is called, since a coach can be put on a custom role.
      is_coach: staff_member.coach?,
      permissions: staff_member.permission_keys,
      active: staff_member.active,
      birthdate: staff_member.birthdate,
      user: {
        id: staff_member.user.id,
        full_name: staff_member.user.full_name,
        email: EmailMask.call(staff_member.user.email),
        phone: staff_member.user.phone
      },
      coach_id: staff_member.coach_id
    }
  end

  private

  attr_reader :staff_member
end
