# A pack is several activities sold as one — "Boxe + Musculation" — for a
# gym that teaches more than one discipline.
#
# It is priced the way an activity is: per formule, on a row of its own
# (contract_type_packs mirrors contract_type_activities), because a pack is
# one more thing a formule can be sold for, not a formule of its own. The
# formule still decides how long it lasts and how many sessions it buys.
#
# A contract names an activity, a pack, or neither (all-access) — never both,
# which the check constraint holds whatever the code above it does.
class CreatePacks < ActiveRecord::Migration[8.1]
  def change
    create_table :packs, id: :uuid do |t|
      t.references :company, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.boolean :active, null: false, default: true
      t.timestamps
    end

    create_table :pack_activities, id: :uuid do |t|
      t.references :pack, type: :uuid, null: false, foreign_key: true
      t.references :activity, type: :uuid, null: false, foreign_key: true
      t.timestamps
    end
    add_index :pack_activities, [ :pack_id, :activity_id ], unique: true

    create_table :contract_type_packs, id: :uuid do |t|
      t.references :contract_type, type: :uuid, null: false, foreign_key: true
      t.references :pack, type: :uuid, null: false, foreign_key: true
      t.decimal :price, precision: 10, scale: 2, null: false
      t.timestamps
    end
    add_index :contract_type_packs, [ :contract_type_id, :pack_id ], unique: true

    add_reference :contracts, :pack, type: :uuid, foreign_key: true
    add_check_constraint :contracts, "activity_id IS NULL OR pack_id IS NULL", name: "contracts_activity_or_pack"
  end
end
