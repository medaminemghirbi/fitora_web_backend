# A new account is on its free trial and nothing else: no plan, no billing
# period. Stamping "starter" on it at signup read as a choice the admin never
# made — on their screens, in the superadmin's counts, on the trial invoice.
# The plan is chosen when Fitora sets up the first payment.
#
# Existing accounts that never paid lose the plan they were given by
# default; their trial invoices lose it too. Paid accounts keep theirs.
class TrialHasNoPlan < ActiveRecord::Migration[8.1]
  def up
    change_column_null :subscriptions, :plan, true
    change_column_default :subscriptions, :plan, from: "starter", to: nil
    change_column_null :invoices, :plan, true
    change_column_default :invoices, :plan, from: "starter", to: nil

    execute <<~SQL
      UPDATE subscriptions SET plan = NULL, billing_period = NULL
      WHERE NOT EXISTS (
        SELECT 1 FROM invoices
        WHERE invoices.subscription_id = subscriptions.id AND invoices.trial = FALSE
      )
    SQL
    execute "UPDATE invoices SET plan = NULL WHERE trial = TRUE"
  end

  def down
    execute "UPDATE subscriptions SET plan = 'starter' WHERE plan IS NULL"
    execute "UPDATE invoices SET plan = 'starter' WHERE plan IS NULL"
    change_column_default :subscriptions, :plan, from: nil, to: "starter"
    change_column_null :subscriptions, :plan, false
    change_column_default :invoices, :plan, from: nil, to: "starter"
    change_column_null :invoices, :plan, false
  end
end
