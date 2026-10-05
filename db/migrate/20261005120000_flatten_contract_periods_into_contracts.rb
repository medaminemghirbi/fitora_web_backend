# A contract is one term: it starts, it ends, it has a price and is paid or
# not. There used to be a Contract with no dates at all, holding a list of
# ContractPeriods that carried everything — so the thing called "contract"
# in the code was not a contract in any sense a gym owner would recognise,
# and renewing took two different paths depending on whether the formule
# changed (a new period under the same contract, or a new contract with no
# link to the old one).
#
# Now each period IS a contract. A renewal is a new contract pointing back
# at the one it follows (renewed_from_id), whatever formule it is for, so a
# member's history is a chain of terms rather than a container of them.
#
# Data: a contract's earliest period is folded into the contract row
# itself; every later period becomes a contract of its own, reusing the
# period's id, chained to the one before it. Bookings and payments follow
# the period they were made against.
#
# Non-destructive on purpose: contract_periods and the old
# bookings/payments.contract_period_id columns are left in place, unread by
# the app, so this can be checked against real data before a later
# migration drops them.
class FlattenContractPeriodsIntoContracts < ActiveRecord::Migration[8.1]
  def up
    change_table :contracts, bulk: true do |t|
      t.integer :status, null: false, default: 0
      t.integer :payment_status, null: false, default: 0
      t.datetime :starts_at
      t.datetime :expires_at
      t.datetime :paused_at
      t.integer :remaining_bookings
      t.decimal :base_price, precision: 10, scale: 2, null: false, default: 0
      t.decimal :discount, precision: 10, scale: 2, null: false, default: 0
      t.decimal :final_price, precision: 10, scale: 2
    end
    add_reference :contracts, :renewed_from, type: :uuid, foreign_key: { to_table: :contracts }
    add_reference :bookings, :contract, type: :uuid, foreign_key: true
    add_reference :payments, :contract, type: :uuid, foreign_key: true

    # Each period, its place in its contract's history, and the contract row
    # it becomes: the contract itself for the first, its own id after that.
    execute <<~SQL.squish
      CREATE TEMP TABLE period_map ON COMMIT DROP AS
      SELECT ranked.id AS period_id, ranked.contract_id, ranked.rn,
             CASE WHEN ranked.rn = 1 THEN ranked.contract_id ELSE ranked.id END AS target_id
      FROM (
        SELECT cp.id, cp.contract_id,
               ROW_NUMBER() OVER (PARTITION BY cp.contract_id
                                  ORDER BY COALESCE(cp.starts_at, cp.created_at), cp.created_at, cp.id) AS rn
        FROM contract_periods cp
      ) ranked
    SQL

    execute <<~SQL.squish
      UPDATE contracts c
      SET status = cp.status, payment_status = cp.payment_status,
          starts_at = cp.starts_at, expires_at = cp.expires_at, paused_at = cp.paused_at,
          remaining_bookings = cp.remaining_bookings, base_price = cp.base_price,
          discount = cp.discount, final_price = cp.final_price
      FROM period_map m JOIN contract_periods cp ON cp.id = m.period_id
      WHERE m.rn = 1 AND c.id = m.contract_id
    SQL

    execute <<~SQL.squish
      INSERT INTO contracts (id, client_id, company_id, contract_type_id, activity_id, pack_id, created_by_id,
                             auto_renew, status, payment_status, starts_at, expires_at, paused_at,
                             remaining_bookings, base_price, discount, final_price, renewed_from_id,
                             created_at, updated_at)
      SELECT cp.id, c.client_id, c.company_id, c.contract_type_id, c.activity_id, c.pack_id, c.created_by_id,
             c.auto_renew, cp.status, cp.payment_status, cp.starts_at, cp.expires_at, cp.paused_at,
             cp.remaining_bookings, cp.base_price, cp.discount, cp.final_price, prev.target_id,
             cp.created_at, cp.updated_at
      FROM period_map m
      JOIN contract_periods cp ON cp.id = m.period_id
      JOIN contracts c ON c.id = m.contract_id
      JOIN period_map prev ON prev.contract_id = m.contract_id AND prev.rn = m.rn - 1
      WHERE m.rn > 1
      ORDER BY m.rn
    SQL

    execute <<~SQL.squish
      UPDATE bookings b SET contract_id = m.target_id
      FROM period_map m WHERE b.contract_period_id = m.period_id
    SQL
    execute <<~SQL.squish
      UPDATE payments p SET contract_id = m.target_id
      FROM period_map m WHERE p.contract_period_id = m.period_id
    SQL

    add_index :contracts, [ :status, :expires_at ]
    add_check_constraint :contracts, "remaining_bookings IS NULL OR remaining_bookings >= 0",
                         name: "contracts_remaining_bookings_not_negative"
  end

  def down
    remove_check_constraint :contracts, name: "contracts_remaining_bookings_not_negative"
    remove_index :contracts, [ :status, :expires_at ]
    # The rows made from later periods share those periods' ids; the periods
    # themselves were never touched, so they still hold the original data.
    execute "UPDATE bookings SET contract_id = NULL"
    execute "UPDATE payments SET contract_id = NULL"
    execute "DELETE FROM contracts WHERE id IN (SELECT id FROM contract_periods)"
    remove_reference :payments, :contract, foreign_key: true
    remove_reference :bookings, :contract, foreign_key: true
    remove_reference :contracts, :renewed_from, foreign_key: { to_table: :contracts }
    change_table :contracts, bulk: true do |t|
      t.remove :status, :payment_status, :starts_at, :expires_at, :paused_at, :remaining_bookings,
               :base_price, :discount, :final_price
    end
  end
end
