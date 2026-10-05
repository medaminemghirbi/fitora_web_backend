# Fitora is sold in two plans now — Starter (the whole product, no member
# app) and Pro (the member app too, and every update) — paid by the month or
# the year. The plan is the admin's account's, not one gym's: one price
# however many salles the admin runs. So the salle-count tiers go (1 / 3 /
# unlimited, and users.company_limit with them) and the subscription moves
# from each company onto the admin.
#
# Also lets one staff login work in several of an admin's salles: a
# moderator posted to two gyms holds a staff record in each.
#
# Existing accounts go on Pro — the member app was open to every gym until
# today, so nobody loses it by this migration.
class SellTwoPlansToTheAccount < ActiveRecord::Migration[8.1]
  def up
    # ---- subscriptions: one per account ------------------------------------
    add_reference :subscriptions, :admin, type: :uuid, foreign_key: { to_table: :users }
    add_column :subscriptions, :plan, :string, null: false, default: "starter"
    add_reference :invoices, :subscription, type: :uuid, foreign_key: true

    execute <<~SQL
      UPDATE subscriptions s SET admin_id = c.admin_id
      FROM companies c WHERE c.id = s.company_id
    SQL

    # The account keeps the subscription of its oldest salle. Every invoice
    # any of its salles was issued moves onto that one, so no history is lost.
    execute <<~SQL
      CREATE TEMP TABLE kept_subscriptions AS
      SELECT DISTINCT ON (s.admin_id) s.id, s.admin_id
      FROM subscriptions s JOIN companies c ON c.id = s.company_id
      ORDER BY s.admin_id, c.created_at, s.created_at
    SQL
    execute <<~SQL
      UPDATE invoices i SET subscription_id = k.id
      FROM companies c JOIN kept_subscriptions k ON k.admin_id = c.admin_id
      WHERE c.id = i.company_id
    SQL
    execute "DELETE FROM subscriptions WHERE id NOT IN (SELECT id FROM kept_subscriptions)"
    execute "DROP TABLE kept_subscriptions"

    remove_reference :subscriptions, :company, type: :uuid, index: { unique: true }, foreign_key: true

    # An invoice whose salle had no subscription row: its account gets one.
    execute <<~SQL
      INSERT INTO subscriptions (id, admin_id, active, billing_period, plan, created_at, updated_at)
      SELECT gen_random_uuid(), c.admin_id, true, 0, 'pro', now(), now()
      FROM companies c
      WHERE NOT EXISTS (SELECT 1 FROM subscriptions s WHERE s.admin_id = c.admin_id)
      GROUP BY c.admin_id
    SQL
    execute <<~SQL
      UPDATE invoices i SET subscription_id = s.id
      FROM companies c JOIN subscriptions s ON s.admin_id = c.admin_id
      WHERE c.id = i.company_id AND i.subscription_id IS NULL
    SQL
    execute "UPDATE subscriptions SET plan = 'pro'"

    # Frozen at issue like the amount: a later change of plan never rewrites
    # what a past invoice says it was for.
    add_column :invoices, :plan, :string, null: false, default: "starter"
    execute "UPDATE invoices SET plan = 'pro'"

    change_column_null :subscriptions, :admin_id, false
    remove_index :subscriptions, :admin_id
    add_index :subscriptions, :admin_id, unique: true

    change_column_null :invoices, :subscription_id, false
    remove_index :invoices, name: "index_invoices_on_company_id_and_period_start"
    remove_reference :invoices, :company, type: :uuid, index: true, foreign_key: true
    add_index :invoices, [ :subscription_id, :period_start ]

    # ---- prices: per plan, not per salle count ------------------------------
    add_column :subscription_prices, :plan, :string
    # The one-salle price was the entry offer, the three-salle one the next
    # step up: the closest thing each plan had to a price before.
    execute "UPDATE subscription_prices SET plan = 'starter' WHERE company_limit = 1"
    execute "UPDATE subscription_prices SET plan = 'pro' WHERE company_limit = 3"
    execute "DELETE FROM subscription_prices WHERE plan IS NULL"
    change_column_null :subscription_prices, :plan, false
    remove_index :subscription_prices, name: "index_subscription_prices_on_currency_and_tier"
    remove_column :subscription_prices, :company_limit
    add_index :subscription_prices, [ :currency, :plan ], unique: true

    remove_column :users, :company_limit

    # ---- one staff login, several salles ------------------------------------
    remove_index :staff_members, :user_id
    add_index :staff_members, :user_id
    add_index :staff_members, [ :user_id, :company_id ], unique: true
  end

  def down
    # A login posted to several salles keeps only its oldest post.
    execute <<~SQL
      DELETE FROM staff_members WHERE id NOT IN (
        SELECT DISTINCT ON (user_id) id FROM staff_members ORDER BY user_id, created_at
      )
    SQL
    remove_index :staff_members, [ :user_id, :company_id ]
    remove_index :staff_members, :user_id
    add_index :staff_members, :user_id, unique: true

    # Nobody was capped before the tiers existed; unlimited is what every
    # account now has.
    add_column :users, :company_limit, :integer, default: 1
    execute "UPDATE users SET company_limit = NULL WHERE role = 0"

    add_column :subscription_prices, :company_limit, :integer, default: 1, null: false
    execute "UPDATE subscription_prices SET company_limit = CASE plan WHEN 'pro' THEN 3 ELSE 1 END"
    remove_index :subscription_prices, [ :currency, :plan ]
    remove_column :subscription_prices, :plan
    add_index :subscription_prices, [ :currency, :company_limit ], unique: true, name: "index_subscription_prices_on_currency_and_tier"

    # Every salle gets its own subscription back, a copy of its account's;
    # the invoices go to the account's oldest salle.
    add_reference :subscriptions, :company, type: :uuid, foreign_key: true
    add_reference :invoices, :company, type: :uuid, foreign_key: true
    execute <<~SQL
      UPDATE invoices i SET company_id = (
        SELECT c.id FROM companies c JOIN subscriptions s ON s.admin_id = c.admin_id
        WHERE s.id = i.subscription_id ORDER BY c.created_at LIMIT 1
      )
    SQL
    execute "DELETE FROM invoices WHERE company_id IS NULL"
    remove_index :invoices, [ :subscription_id, :period_start ]
    remove_column :invoices, :plan
    remove_reference :invoices, :subscription, type: :uuid, index: true, foreign_key: true
    change_column_null :invoices, :company_id, false
    add_index :invoices, [ :company_id, :period_start ]

    remove_index :subscriptions, :admin_id
    execute <<~SQL
      INSERT INTO subscriptions (id, company_id, admin_id, active, billing_period, plan, created_at, updated_at)
      SELECT gen_random_uuid(), c.id, s.admin_id, s.active, s.billing_period, s.plan, s.created_at, now()
      FROM companies c JOIN subscriptions s ON s.admin_id = c.admin_id
    SQL
    execute "DELETE FROM subscriptions WHERE company_id IS NULL"

    remove_reference :subscriptions, :admin, type: :uuid, index: false, foreign_key: { to_table: :users }
    remove_column :subscriptions, :plan
    change_column_null :subscriptions, :company_id, false
    remove_index :subscriptions, :company_id
    add_index :subscriptions, :company_id, unique: true
  end
end
