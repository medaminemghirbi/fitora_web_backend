class AuditLog < ApplicationRecord
  belongs_to :company
  belongs_to :user, optional: true

  validates :action, presence: true
  validates :auditable_type, presence: true
  validates :auditable_id, presence: true

  scope :recent, -> { order(created_at: :desc) }

  def self.record!(company:, user:, action:, auditable:, metadata: {})
    create!(
      company: company,
      user: user,
      action: action,
      auditable_type: auditable.class.name,
      auditable_id: auditable.id,
      metadata: metadata.merge(impersonation_metadata)
    )
  end

  # A Gymly superadmin impersonating an admin acts AS that admin — that is the
  # point of impersonation, and it means an audit log would otherwise
  # record the admin refunding a payment the superadmin refunded. Stamp who was
  # really acting, on every entry, without every call site having to
  # remember to.
  def self.impersonation_metadata
    superadmin = Current.impersonator
    return {} if superadmin.nil?

    { impersonated_by_id: superadmin.id, impersonated_by_email: superadmin.email }
  end
  private_class_method :impersonation_metadata

  def auditable
    auditable_type.constantize.find_by(id: auditable_id)
  end
end
