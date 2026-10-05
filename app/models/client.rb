# A person a gym trains. The record exists because staff created it, and the
# gym is what the person joined — there is no directory to find one in and no
# way to sign yourself up.
#
# They may still be given a way in, from their own file: an account the gym
# enables so they can read their gym's schedule, book a slot, cancel it, and
# see their own subscription and attendance. Off by default, and the gym's to
# grant — which is why there is no pairing key. A key exists to attach a
# device that has no account; these have one.
#
# The record is global rather than owned by one gym — the same person
# training at two gyms is one Client with two Memberships — so that a gym
# recording an existing email adopts the person instead of duplicating them.
# Each gym still only ever sees its own membership, contracts and payments.
class Client < ApplicationRecord
  include PasswordResettable
  include EmailVerifiable
  include TokenVersioned
  include Invitable

  has_many :memberships, dependent: :destroy
  has_many :companies, through: :memberships

  has_many :bookings, dependent: :destroy
  has_many :contracts, dependent: :destroy
  has_many :payments, dependent: :destroy
  # What their own app tells them: a class called off, a seat from the
  # waitlist, a subscription running out.
  has_many :notifications, as: :recipient, dependent: :destroy

  # Optional, unlike User's: a walk-in the gym wrote down is a perfectly
  # valid member with no login at all. The member sets one by accepting an
  # invitation the gym sends (Api::V1::ClientsController#invite) — staff
  # never choose it.
  has_secure_password validations: false

  # A member with no email has NULL, never "".
  #
  # The guard here used to be `if email.present?`, which left an empty string
  # exactly as the form sent it. The unique index on lower(email) exempts
  # NULL but not "", so the first member saved without an email took the ""
  # slot and the second hit a duplicate-key 500 — a gym adding two members
  # off a phone number could not save the second.
  before_validation { self.email = email.to_s.downcase.strip.presence }
  validates :first_name, :last_name, :phone, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  # The email IS the person now: unique across the platform, so the same human
  # signing up at a second gym lands on their existing account instead of a
  # duplicate. A walk-in a gym recorded with no email is still valid.
  validates :email, uniqueness: { case_sensitive: false }, allow_blank: true
  # An account has to be reachable: the email is both the identifier and
  # where the invitation goes.
  validates :email, presence: true, if: -> { password_digest.present? }
  validates :password, length: { minimum: 8 }, if: -> { password.present? }

  scope :active, -> { where(active: true) }
  scope :search, ->(term) {
    return all if term.blank?

    sanitized = "%#{term.strip}%"
    where("first_name ILIKE :t OR last_name ILIKE :t OR phone ILIKE :t OR email ILIKE :t", t: sanitized)
  }

  # What a person who has left Fitora is called on the gyms' books.
  PLACEHOLDER_FIRST_NAME = "Ancien".freeze
  PLACEHOLDER_LAST_NAME = "membre".freeze

  def self.find_by_email(email)
    return nil if email.blank?

    where("lower(email) = ?", email.to_s.downcase.strip).first
  end

  # Adds someone to a gym and returns them.
  #
  # The email identifies the person across the platform, so an address that
  # already has an account joins that person rather than creating a second
  # one (#previously_new_record? tells the two apart afterwards). Their
  # identity is theirs: only what it left blank is filled in. What the gym
  # writes about them (date of birth, address, notes…) goes on this gym's
  # membership, never on the shared person.
  def self.enrol!(company, person:, membership: {})
    person = person.to_h.stringify_keys
    membership = membership.to_h.stringify_keys
    client = find_by_email(person["email"]) || new
    client.assign_attributes(client.new_record? ? person : person.reject { |key, _| client.public_send(key).present? })

    transaction do
      client.save!
      joined = client.join!(company)
      joined.update!(membership) if membership.any?
    end
    client
  end

  def full_name
    "#{first_name} #{last_name}"
  end

  def login_enabled?
    password_digest.present?
  end

  # What identifies the person, as opposed to what one gym wrote down about
  # them (which lives on Membership).
  IDENTITY_FIELDS = %w[first_name last_name email phone].freeze

  # Whether the name, email and phone are still this gym's to change. Once
  # the person signs in themselves, has been invited to, or trains somewhere
  # else too, they are not: one gym editing them would be editing them for
  # everyone. A gym can still fill in whatever is blank.
  def identity_shared_beyond?(company)
    login_enabled? || invitation_pending? || memberships.where.not(company_id: company.id).exists?
  end

  def membership_for(company)
    memberships.find_by(company_id: company.is_a?(Company) ? company.id : company)
  end

  # Joining is instant — there is nothing to approve. Called when a gym adds
  # someone, and when a gym records an email another gym already has.
  def join!(company)
    memberships.find_or_create_by!(company_id: company.id)
  end

  # A gym letting a member go, and taking what it wrote about them with it.
  # Returns whether that left nothing to keep, so the person was anonymised.
  #
  # The membership — with this gym's notes and its copy of their details — is
  # deleted, and their upcoming bookings here are cancelled. The contracts and
  # payments stay: they are this gym's books. Someone still subscribed is
  # refused: the subscription is ended first, deliberately, not as a side
  # effect of a delete.
  def remove_from!(company)
    if current_contract(company)
      raise Refused, "This member still has an active subscription. End it before removing them."
    end

    transaction do
      bookings_for(company).where(status: %i[confirmed waitlisted]).where(sessions: { starts_at: Time.current.. })
                           .find_each(&:cancel!)
      membership_for(company)&.destroy!

      # A person who belongs to no gym and never had a login of their own has
      # nobody left to keep the record for.
      if memberships.reload.none? && !login_enabled?
        anonymise!
        true
      else
        false
      end
    end
  end

  # Erases this person from Fitora while keeping the gyms' books whole.
  #
  # Contracts, payments and past bookings stay — a gym's accounts cannot lose
  # rows because a member left — but nothing on them points at a
  # recognisable human any more: the name becomes a placeholder, the email,
  # phone and password go, every gym's copy of their details is wiped, every
  # upcoming booking is cancelled and every session ends.
  def anonymise!
    transaction do
      bookings.where(status: %i[confirmed waitlisted]).joins(:session).where(sessions: { starts_at: Time.current.. })
              .find_each(&:cancel!)

      memberships.update_all( # rubocop:disable Rails/SkipsModelValidations
        Membership::PROFILE_FIELDS.index_with(nil).merge("notes" => nil, "active" => false, "updated_at" => Time.current)
      )

      # Past validation on purpose: a placeholder has no phone, and the
      # point is that it has nothing.
      update_columns( # rubocop:disable Rails/SkipsModelValidations
        first_name: PLACEHOLDER_FIRST_NAME, last_name: PLACEHOLDER_LAST_NAME,
        email: nil, phone: nil, password_digest: nil, active: false,
        email_verified_at: nil, email_verification_token_digest: nil, email_verification_sent_at: nil,
        reset_password_token_digest: nil, reset_password_sent_at: nil,
        invitation_token_digest: nil, invitation_sent_at: nil,
        token_version: token_version + 1, updated_at: Time.current
      )
    end
  end

  # ---- per-gym views -------------------------------------------------------
  # A person now belongs to several gyms, so everything below takes the gym
  # being looked at. Passing nil means "across every gym" — only the person's
  # own account screens do that; a gym ALWAYS passes itself, otherwise one
  # gym would read another gym's contracts, money and attendance.

  def contracts_for(company)
    company ? contracts.where(company_id: company.id) : contracts
  end

  def bookings_for(company)
    return bookings if company.nil?

    bookings.joins(:session).where(sessions: { company_id: company.id })
  end

  def payments_for(company)
    company ? payments.where(company_id: company.id) : payments
  end

  # The active contract in force — the earliest-starting one still running,
  # so a renewal queued behind the current term doesn't stand in for it.
  def current_contract(company = nil)
    contracts_for(company).currently_active.order(CURRENT_CONTRACT_ORDER).first
  end

  CURRENT_CONTRACT_ORDER = Arel.sql("contracts.starts_at ASC NULLS FIRST, contracts.created_at ASC")

  # What's still owed: unpaid bookings and contracts, net of any payments
  # already recorded against them. Not a full accounting ledger — just
  # enough to flag a client with a balance due.
  def outstanding_balance(company = nil)
    owed = bookings_for(company).unpaid.sum(:amount) + contracts_for(company).unpaid.sum(:final_price)
    paid_scope = payments_for(company).paid
    received = paid_scope.where.not(booking_id: nil).sum(:amount) +
               paid_scope.where.not(contract_id: nil).sum(:amount)
    [ owed - received, 0 ].max
  end

  def attendance_rate(company = nil)
    records = AttendanceRecord.where(booking_id: bookings_for(company).select(:id))
    total = records.count
    return nil if total.zero?

    (records.present.count.to_f / total * 100).round
  end
end
