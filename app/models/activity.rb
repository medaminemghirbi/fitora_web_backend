class Activity < ApplicationRecord
  belongs_to :company
  # The catalogue entry this activity was copied from, if any (see
  # ActivityTemplate). Only a record of where it came from: the activity is
  # the gym's own and never reads anything back from the template.
  belongs_to :activity_template, optional: true

  has_many :sessions, dependent: :destroy
  has_many :contract_type_activities, dependent: :destroy
  has_many :contract_types, through: :contract_type_activities
  has_many :pack_activities, dependent: :destroy
  has_many :packs, through: :pack_activities

  # The rooms this activity may run in. EMPTY means "anywhere" — see
  # ActivitySpace. Never read `spaces` to answer "where can this run?";
  # ask Space.available_for(activity), which handles the empty case.
  has_many :activity_spaces, dependent: :destroy
  has_many :spaces, through: :activity_spaces

  # How many people a session of this activity is for. The admin picks the
  # format; it constrains the capacity (see CAPACITY_BOUNDS + the validation).
  #   individual   → 1-on-1 (capacity 1)
  #   small_group  → small group (capacity 2–9)
  #   collective   → class (capacity 10+)
  # ("group" alone would collide with an Active Record class method.)
  # `attribute` must precede `enum` or the dev code-reloader raises
  # "Undeclared attribute type for enum" after the column rename migration.
  attribute :session_format, :integer
  enum :session_format, { individual: 0, small_group: 1, collective: 2 }

  CAPACITY_BOUNDS = {
    "individual"  => { min: 1,  max: 1 },
    "small_group" => { min: 2,  max: 9 },
    "collective"  => { min: 10, max: nil }
  }.freeze

  validates :name, presence: true
  validates :duration, numericality: { greater_than: 0 }
  validates :capacity, numericality: { greater_than: 0 }
  validate :capacity_matches_session_format

  scope :active, -> { where(active: true) }


  private

  def capacity_matches_session_format
    return if session_format.blank? || capacity.blank?

    bounds = CAPACITY_BOUNDS[session_format]
    return if bounds.nil?
    return if capacity >= bounds[:min] && (bounds[:max].nil? || capacity <= bounds[:max])

    errors.add(:capacity, capacity_range_message(bounds))
  end

  def capacity_range_message(bounds)
    label = "#{session_format.tr('_', '-')} activity"
    if bounds[:max].nil?
      "must be at least #{bounds[:min]} for a #{label}"
    elsif bounds[:min] == bounds[:max]
      "must be #{bounds[:min]} for an #{label}"
    else
      "must be between #{bounds[:min]} and #{bounds[:max]} for a #{label}"
    end
  end
end
