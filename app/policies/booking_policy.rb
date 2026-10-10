class BookingPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    staff_access?
  end

  # record is the booking about to be made (unsaved, its session set): a
  # coach holding `bookings` books onto their own sessions only, the same
  # narrowing as every other action here.
  def create?
    staff_access?
  end

  def cancel?
    staff_access?
  end

  def remind?
    staff_access?
  end

  private

  # Admin always; staff need the `bookings` capability (manager, moderator,
  # or a coach — narrowed to bookings on their own sessions only).
  def staff_access?
    return false if record.session.company_id != user.current_company&.id

    return true if user.admin?

    staff = user.staff_member
    return false unless staff&.active? && staff.can?(:bookings)

    staff.coach? ? record.session.coach_id == staff.coach_id : true
  end
end
