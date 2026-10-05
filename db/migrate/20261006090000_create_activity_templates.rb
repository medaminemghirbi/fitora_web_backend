# A platform-wide catalogue of disciplines — Pilates Reformer, EMS, Boxe —
# that a gym picks from when it opens, instead of typing its first activity
# into an empty form.
#
# A template is a starting point, never a shared row: adopting one COPIES it
# into the gym's own `activities` (name in the gym's language, format,
# duration, capacity), which the gym then owns and edits like any other.
# Changing a template later only changes what the next gym gets. The link
# (activities.activity_template_id) is kept so the platform can tell which
# gyms teach what — the public directory, the superadmin's figures — and is
# NULL for an activity the gym made up itself.
class CreateActivityTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :activity_templates, id: :uuid do |t|
      t.string :key, null: false
      t.string :family, null: false
      t.string :emoji
      # { "fr" => "Pilates Reformer", "en" => "Reformer Pilates", "ar" => "بيلاتس ريفورمر" }
      t.jsonb :names, null: false, default: {}
      t.integer :session_format, null: false, default: 2
      t.integer :duration, null: false, default: 60
      t.integer :capacity, null: false, default: 15
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :activity_templates, :key, unique: true
    add_index :activity_templates, [ :family, :position ]

    add_reference :activities, :activity_template, type: :uuid, foreign_key: true
  end
end
