class StaffMember < ApplicationRecord
  belongs_to :user
  belongs_to :company
  # A staff login IS a coach when it has a coach to be. This is the whole
  # definition — there is no separate "kind" column saying so any more, and
  # the places that narrow a coach to their own sessions all read coach_id
  # anyway, so keying #coach? off it makes the check honest.
  belongs_to :coach, optional: true
  # The role this login is assigned to: the single source of its permissions
  # and the name the UI calls it by. Required — a staff member with no role
  # is a login that can do nothing, which is never what anyone meant.
  belongs_to :assigned_role, class_name: "Role", foreign_key: :role_id, inverse_of: :staff_members,
                              counter_cache: :staff_members_count

  # One record per salle: a login posted to two of an admin's salles has
  # two, never two in the same one.
  validates :user_id, uniqueness: { scope: :company_id }
  validate :coach_belongs_to_same_company
  validate :role_belongs_to_same_company
  # A salle runs with at most one active login on the built-in moderator
  # role. Other back-office roles (custom ones: "Comptable", "Réception"…)
  # and coaches are not capped. Checked only when a record would become that
  # moderator, so a salle that already had two before the rule can still
  # edit them.
  validate :one_moderator_per_company, if: :becoming_moderator?

  MODERATOR_ROLE_KEY = "moderator".freeze

  scope :active, -> { where(active: true) }
  # Logins holding the moderator role itself — not every back-office login.
  scope :moderators, -> { where(coach_id: nil).joins(:assigned_role).where(roles: { key: MODERATOR_ROLE_KEY }) }

  def can?(capability)
    permission_keys.include?(capability.to_s)
  end

  def full_name
    user&.full_name
  end

  # True on the person's birthday (day + month), any year.
  def birthday_today?(on: Date.current)
    birthdate.present? && birthdate.strftime("%m-%d") == on.strftime("%m-%d")
  end

  # This login coaches: it has a Coach row of its own. The narrowing checks
  # (own sessions, own bookings, own attendance) all read coach_id, so this
  # asks exactly what they use.
  def coach?
    coach_id.present?
  end

  # What the UI and the audit log identify the role by.
  def role_key
    assigned_role.key
  end

  # The resolved permission list for this staff login.
  def permission_keys
    assigned_role.permissions
  end

  private

  def becoming_moderator?
    # The association, not coach_id: a coach handed in unsaved has no id yet.
    return false unless active? && coach.nil? && assigned_role&.key == MODERATOR_ROLE_KEY

    new_record? || will_save_change_to_active? || will_save_change_to_coach_id? ||
      will_save_change_to_company_id? || will_save_change_to_role_id?
  end

  def one_moderator_per_company
    others = StaffMember.active.moderators.where(company_id: company_id).where.not(id: id)
    errors.add(:base, "This salle already has a moderator.") if others.exists?
  end

  def role_belongs_to_same_company
    return if assigned_role.blank? || company_id.blank?

    errors.add(:assigned_role, "must belong to the same company") if assigned_role.company_id != company_id
  end

  def coach_belongs_to_same_company
    return if coach.blank?

    errors.add(:coach, "must belong to the same company") if coach.company_id != company_id
  end
end
