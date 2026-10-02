class User < ApplicationRecord
  has_secure_password
  include PasswordResettable
  include EmailVerifiable
  include TokenVersioned

  # A User is always staff: the Gymly-operator ("superadmin", manages every
  # company's SaaS subscription via /superadmin) or an in-gym account
  # (admin, or staff — the specific in-gym role lives on StaffMember).
  # Clients are business records the gym creates, never Users — see Client.
  enum :role, { admin: 0, staff: 1, superadmin: 2 }


  # An admin runs as many salles as they like (each a fully independent
  # tenant — its own clients, staff) under one subscription, the account's.
  # active_company is which salle their session is currently scoped to —
  # see #current_company and Api::V1::CompaniesController#switch.
  has_many :companies, foreign_key: :admin_id, inverse_of: :admin, dependent: :destroy
  # Everything across the salles an admin runs — what their account covers.
  has_many :salle_memberships, through: :companies, source: :memberships
  has_many :salle_staff_members, through: :companies, source: :staff_members
  has_one :subscription, foreign_key: :admin_id, inverse_of: :admin, dependent: :destroy
  belongs_to :active_company, class_name: "Company", optional: true
  # A staff login holds one record per salle it works in: a moderator the
  # admin posted to two salles has two, each with that salle's own role.
  # active_company picks which one the session is working in.
  has_many :staff_members, dependent: :destroy
  has_many :staffed_companies, through: :staff_members, source: :company
  has_many :notifications, as: :recipient, dependent: :destroy

  before_validation { self.email = email.to_s.downcase.strip }

  validates :first_name, :last_name, presence: true
  validates :email, presence: true, uniqueness: true,
                     format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, if: -> { new_record? || password.present? }
  validates :locale, inclusion: { in: %w[fr en ar] }

  scope :active, -> { where(active: true) }

  def full_name
    "#{first_name} #{last_name}"
  end

  # Signed up, and the address not confirmed yet: nothing past sign-up
  # opens until it is. Admins only — see EmailVerifiable.
  def email_confirmation_pending?
    admin? && !email_verified?
  end

  # The salle this login is working in right now. An admin's is the one
  # they switched to; a staff login's is the salle of its current staff
  # record, which is never a salle it no longer works in — active_company
  # alone could still name one the admin has since withdrawn it from.
  def current_company
    return active_company if admin?

    staff_member&.company
  end

  # This staff login's record in the salle it is working in: the one for
  # active_company, else its first active post, else its first. nil for an
  # admin or superadmin.
  def staff_member
    return @staff_member if defined?(@staff_member_for) && @staff_member_for == active_company_id

    @staff_member_for = active_company_id
    @staff_member =
      (active_company_id && staff_members.find_by(company_id: active_company_id)) ||
      staff_members.active.order(:created_at).first ||
      staff_members.order(:created_at).first
  end

  def reload(*)
    remove_instance_variable(:@staff_member_for) if defined?(@staff_member_for)
    super
  end

  # The salles this login can switch between: every salle an admin runs, or
  # every salle a staff login is posted to and still active in.
  def workplaces
    return companies if admin?

    Company.where(id: staff_members.active.select(:company_id))
  end

  # Moves the session onto another of this login's OWN salles — never onto
  # one it does not run or work in, since that's exactly the cross-tenant
  # boundary current_company exists to enforce.
  def switch_active_company!(company)
    return false unless workplaces.exists?(company.id)

    update!(active_company: company)
  end
end
