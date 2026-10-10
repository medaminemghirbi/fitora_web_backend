class Coach < ApplicationRecord
  include UnmaskedEmail
  belongs_to :company

  has_many :sessions, dependent: :nullify
  has_one :staff_member, dependent: :nullify

  validates :first_name, :last_name, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true

  scope :active, -> { where(active: true) }

  def full_name
    "#{first_name} #{last_name}"
  end

  # True on the person's birthday (day + month), any year.
  def birthday_today?(on: Date.current)
    birthdate.present? && birthdate.strftime("%m-%d") == on.strftime("%m-%d")
  end

  # Gives this coach a login of their own and returns its staff record. A
  # coach who already has one (set up by the admin earlier, or by an earlier
  # call here) just has its email and password reset; otherwise a fresh
  # staff account on the coach role is provisioned and linked.
  def set_login!(email:, password:)
    transaction do
      record = staff_member || create_staff_login!(email, password)
      record.user.update!(email: email, password: password)
      record.reload
    end
  end

  private

  def create_staff_login!(email, password)
    user = User.create!(
      first_name: first_name, last_name: last_name,
      email: email, password: password, role: :staff, locale: "fr"
    )
    company.staff_members.create!(user: user, assigned_role: coach_role, coach: self)
  end

  # The company's built-in coach role. Seeded with every company, but a
  # gym created before the role table existed may not have it — seed it
  # rather than fail provisioning a login over it.
  def coach_role
    company.roles.find_by(key: "coach") || begin
      Role.seed_defaults_for(company)
      company.roles.find_by!(key: "coach")
    end
  end
end
