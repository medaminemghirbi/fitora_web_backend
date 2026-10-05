# Several activities sold as one — "Boxe + Musculation" — for a gym that
# teaches more than one discipline.
#
# A pack has no price and no duration of its own: like an activity, it is
# priced per formule (ContractTypePack), and the formule decides how long a
# purchase lasts and how many sessions it buys. What the pack adds is the
# set of activities one abonnement opens.
class Pack < ApplicationRecord
  belongs_to :company

  has_many :pack_activities, dependent: :destroy
  has_many :activities, through: :pack_activities
  has_many :contract_type_packs, dependent: :destroy
  has_many :contract_types, through: :contract_type_packs
  has_many :contracts, dependent: :restrict_with_error

  validates :name, presence: true
  validate :bundles_several_activities
  validate :activities_belong_to_company

  scope :active, -> { where(active: true) }

  # Read from the loaded rows, so a list that preloaded them asks nothing more.
  def covers?(activity)
    return false if activity.blank?

    pack_activities.any? { |row| row.activity_id == activity.id }
  end

  # "Boxe, Musculation" — what the pack opens, for a label.
  def activity_names
    activities.map(&:name).sort
  end

  private

  # A pack of one activity is that activity under another name, and would
  # sell beside it at a second price.
  def bundles_several_activities
    errors.add(:activities, "must include at least two activities") if activities.size < 2
  end

  def activities_belong_to_company
    return if activities.all? { |activity| activity.company_id == company_id }

    errors.add(:activities, "must belong to this gym")
  end
end
