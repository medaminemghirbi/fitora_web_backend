class Notification < ApplicationRecord
  # The admin's and the superadmin's kinds, then a member's own.
  KINDS = %w[
    contract_expiring employee_birthday system_update invoice_issued
    session_cancelled waitlist_promoted subscription_expiring
  ].freeze

  # Company-scoped events (contract expiry, birthdays) always carry
  # one; a platform-level event fanned out to Gymly superadmins (system_update)
  # has none — those recipients don't belong to any company.
  belongs_to :company, optional: true
  # A User (an admin, or a Gymly superadmin) or a Client (a member, on their
  # own app).
  belongs_to :recipient, polymorphic: true
  belongs_to :subject, polymorphic: true, optional: true

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :url, presence: true
  validates :dedup_key, presence: true, uniqueness: { scope: :company_id }

  scope :unread, -> { where(read_at: nil) }
  scope :recent, -> { order(created_at: :desc) }

  # created_at is set explicitly (the table has no updated_at).
  before_validation :stamp_created_at, on: :create

  after_create_commit :broadcast

  # Creates one notification per (company, dedup_key), idempotently — safe to
  # call from a daily scan and from a synchronous after_commit hook. Returns
  # nil when there is nobody to tell.
  #
  # `company` is required for a member: they belong to several gyms, and the
  # notification comes from one of them. For a User it is derived.
  def self.push(recipient:, kind:, data:, url:, dedup_key:, subject: nil, company: nil)
    return nil if recipient.nil?

    if recipient.is_a?(Client)
      # Nobody to tell: a member without their app never reads these.
      return nil if company.nil? || !recipient.login_enabled?
    else
      # Every company-scoped notification still requires one (a nil company
      # here would silently be a bug in the caller); a platform-level event
      # aimed at a Gymly superadmin has none by design — see #company.
      company = recipient.current_company
      return nil if company.nil? && !recipient.superadmin?
    end

    recipient.notifications.create!(
      company: company,
      kind: kind,
      data: data,
      url: url,
      dedup_key: dedup_key,
      subject: subject
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    # Unique index on [company_id, dedup_key] — already notified. Not an error.
    raise unless e.is_a?(ActiveRecord::RecordNotUnique) || e.record&.errors&.of_kind?(:dedup_key, :taken)

    recipient.notifications.find_by(dedup_key: dedup_key)
  end

  def read?
    read_at.present?
  end

  def mark_read!
    update!(read_at: Time.current) unless read?
    broadcast_unread_count
  end

  def broadcast_unread_count
    NotificationChannel.broadcast_to(
      recipient,
      { type: "unread_count", count: recipient.notifications.unread.count }
    )
  end

  private

  def stamp_created_at
    self.created_at ||= Time.current
  end

  def broadcast
    NotificationChannel.broadcast_to(
      recipient,
      NotificationSerializer.new(self).as_json.merge(type: "created")
    )
    broadcast_unread_count
  end
end
