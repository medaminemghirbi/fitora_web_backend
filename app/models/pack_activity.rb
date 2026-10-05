# One activity a pack opens.
class PackActivity < ApplicationRecord
  belongs_to :pack
  belongs_to :activity

  validates :activity_id, uniqueness: { scope: :pack_id }
end
