# One discipline in the platform-wide catalogue a gym picks its activities
# from (see the create_activity_templates migration). Global, not a tenant
# model: every gym reads the same catalogue, and only adopting a template
# writes anything into a gym — a copy of its own.
class ActivityTemplate < ApplicationRecord
  # The groups the picker shows the catalogue in, in this order.
  FAMILIES = %w[fitness wellness combat tech aquatic dance outdoor].freeze

  has_many :activities, dependent: :nullify

  # Same values as Activity's, so a template's format copies straight across.
  attribute :session_format, :integer
  enum :session_format, { individual: 0, small_group: 1, collective: 2 }

  validates :key, presence: true, uniqueness: true
  validates :family, inclusion: { in: FAMILIES }
  validates :duration, numericality: { greater_than: 0 }
  validates :capacity, numericality: { greater_than: 0 }
  validate :named_in_french

  scope :active, -> { where(active: true) }
  scope :catalogue_order, -> { in_order_of(:family, FAMILIES).order(:position, :key) }

  # The name in `locale`, falling back to French, the language every
  # template is guaranteed to have.
  def name_for(locale)
    names[locale.to_s].presence || names["fr"]
  end

  # What adopting this template creates in a gym: the gym's own activity,
  # named in the gym's language.
  def activity_attributes_for(company)
    {
      activity_template: self,
      name: name_for(company.locale),
      emoji: emoji,
      session_format: session_format,
      duration: duration,
      capacity: capacity
    }
  end

  private

  def named_in_french
    errors.add(:names, "must include a French name") if names.blank? || names["fr"].blank?
  end
end
