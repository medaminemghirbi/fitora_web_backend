class UserSerializer
  def initialize(user)
    @user = user
  end

  def as_json(*)
    {
      id: user.id,
      first_name: user.first_name,
      last_name: user.last_name,
      full_name: user.full_name,
      email: user.email,
      phone: user.phone,
      role: user.role,
      locale: user.locale,
      email_verified: user.email_verified?,
      # The "check your inbox" screen counts down to its resend button from
      # here, so a reload does not hand out a fresh sixty seconds.
      email_verification_resend_in: user.email_verification_resend_in,
      company_id: user.current_company&.id,
      # The key of the role this login is assigned to — "moderator",
      # "coach", or a custom role's own slug.
      staff_role: user.staff_member&.role_key,
      # Whether this login coaches, which is a different question from what
      # its role is called: an admin can build a custom role and give it to
      # a coach. The coach shell and the post-login redirect key off this.
      is_coach: user.staff_member&.coach? || false,
      companies: workplaces
    }
  end

  private

  attr_reader :user

  # The salles this login can switch between. An admin always gets theirs
  # (the switcher is also their way to "Mes salles"); a staff login only
  # when it is posted to more than one. nil (not []) for anyone else, so
  # the frontend can tell "no switcher" apart from "switcher, empty".
  def workplaces
    return nil if user.superadmin?

    places = user.workplaces.order(:created_at).to_a
    return nil if user.staff? && places.size < 2

    current_id = user.current_company&.id
    places.map { |c| CompanySummarySerializer.new(c, active: c.id == current_id).as_json }
  end
end
