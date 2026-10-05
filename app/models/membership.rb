# A person's link to one gym. The person (Client) is global — one row per
# human, identified by their email — and belongs to as many gyms as they like;
# everything the gym owns about them (when they joined, whether they are still
# active there, the gym's private notes, and the personal details it wrote
# down — date of birth, gender, address, emergency contact) lives here, not on
# the person. A second gym that records the same email starts with a blank
# copy: it never reads what the first gym wrote.
class Membership < ApplicationRecord
  belongs_to :client
  belongs_to :company

  before_validation { self.joined_at ||= Time.current }

  validates :client_id, uniqueness: { scope: :company_id }

  # What a gym may write about the person it trains, all on its own copy.
  # health_notes are the contraindications a coach has to know before an EMS
  # or reformer session (pacemaker, pregnancy, a back injury);
  # waiver_signed_on is when the member signed the studio's health
  # declaration. Both are wiped with the rest on Client#anonymise!.
  PROFILE_FIELDS = %w[
    date_of_birth gender address emergency_contact_name emergency_contact_phone health_notes waiver_signed_on
  ].freeze

  scope :active, -> { where(active: true) }
end
