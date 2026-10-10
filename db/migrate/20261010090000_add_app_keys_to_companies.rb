# The two keys that turn the generic Fitora app into one salle's app
# (mobile/src/lib/tenant-config.ts): the member code, typed or scanned by
# members, and the coach key, which also lists the salle's staff to sign in
# as — so it is longer and kept apart. Both are generated on first use and
# can be regenerated from Settings → Application mobile (a Pro tool).
class AddAppKeysToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :app_code, :string
    add_column :companies, :coach_key, :string
    add_index :companies, :app_code, unique: true
    add_index :companies, :coach_key, unique: true
  end
end
