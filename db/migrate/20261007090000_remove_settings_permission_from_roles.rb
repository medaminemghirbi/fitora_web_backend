# "settings" is gone from Permission::CATALOG: no endpoint ever checked it,
# company settings being the admin's alone. Role#normalise would drop it on
# each role's next save anyway; this clears it now so no stored role still
# lists it.
class RemoveSettingsPermissionFromRoles < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE roles SET permissions = array_remove(permissions, 'settings') WHERE 'settings' = ANY(permissions)"
  end

  def down
    # Nothing to restore: the key granted nothing.
  end
end
