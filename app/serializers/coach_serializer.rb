class CoachSerializer
  # `reveal`: the whole e-mail addresses — an admin opening one coach to
  # edit it. Lists and everyone else get them masked (EmailMask).
  def initialize(coach, reveal: false)
    @coach = coach
    @reveal = reveal
  end

  def as_json(*)
    {
      id: coach.id,
      company_id: coach.company_id,
      first_name: coach.first_name,
      last_name: coach.last_name,
      full_name: coach.full_name,
      email: shown(coach.email),
      phone: coach.phone,
      bio: coach.bio,
      photo_url: coach.photo_url,
      birthdate: coach.birthdate,
      active: coach.active,
      has_login: coach.staff_member.present?,
      login_email: shown(coach.staff_member&.user&.email)
    }
  end

  def shown(email)
    @reveal ? email : EmailMask.call(email)
  end

  private

  attr_reader :coach
end
