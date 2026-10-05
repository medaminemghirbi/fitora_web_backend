# One cell of a formule's pricing grid, for a pack rather than an activity:
# what the pack costs under this formule. As with ContractTypeActivity, the
# row existing is what makes the pack sellable under the formule.
class ContractTypePack < ApplicationRecord
  belongs_to :contract_type
  belongs_to :pack

  validates :pack_id, uniqueness: { scope: :contract_type_id }
  validates :price, numericality: { greater_than_or_equal_to: 0 }
end
