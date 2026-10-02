# Gymly's whole schema, created in one step.
#
# The history that led here — renames, backfills, columns added and dropped
# — was squashed before there was any production data to carry: a new
# database needs only what the schema is now. The version is the last one
# the old history reached, so a database built from it counts this as run.
#
# Reference data (subscription prices, platform settings, the superadmin
# login) is db/seeds.rb's; a company's built-in roles are seeded by the app
# when it opens (Company.open!).
class CreateGymlySchema < ActiveRecord::Migration[8.1]
  def change
    enable_extension "btree_gist"
    enable_extension "pg_trgm"
    enable_extension "pgcrypto"

    create_table "active_storage_attachments", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid "blob_id", null: false
      t.datetime "created_at", null: false
      t.string "name", null: false
      t.uuid "record_id", null: false
      t.string "record_type", null: false
      t.index [ "blob_id" ], name: "index_active_storage_attachments_on_blob_id"
      t.index [ "record_type", "record_id", "name", "blob_id" ], name: "index_active_storage_attachments_uniqueness", unique: true
    end

    create_table "active_storage_blobs", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.bigint "byte_size", null: false
      t.string "checksum"
      t.string "content_type"
      t.datetime "created_at", null: false
      t.string "filename", null: false
      t.string "key", null: false
      t.text "metadata"
      t.string "service_name", null: false
      t.index [ "key" ], name: "index_active_storage_blobs_on_key", unique: true
    end

    create_table "active_storage_variant_records", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid "blob_id", null: false
      t.string "variation_digest", null: false
      t.index [ "blob_id", "variation_digest" ], name: "index_active_storage_variant_records_uniqueness", unique: true
    end

    create_table "activities", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.boolean "active", default: true, null: false
      t.integer "capacity", default: 1, null: false
      t.uuid "company_id", null: false
      t.datetime "created_at", null: false
      t.text "description"
      t.integer "duration", null: false
      t.string "emoji"
      t.string "name", null: false
      t.integer "session_format", default: 1, null: false
      t.datetime "updated_at", null: false
      t.index [ "company_id" ], name: "index_activities_on_company_id"
      t.index [ "name" ], name: "index_activities_on_name_trgm", opclass: :gin_trgm_ops, using: :gin
    end

    create_table "activity_spaces", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid "activity_id", null: false
      t.datetime "created_at", null: false
      t.uuid "space_id", null: false
      t.datetime "updated_at", null: false
      t.index [ "activity_id", "space_id" ], name: "index_activity_spaces_on_activity_id_and_space_id", unique: true
      t.index [ "activity_id" ], name: "index_activity_spaces_on_activity_id"
      t.index [ "space_id" ], name: "index_activity_spaces_on_space_id"
    end

    create_table "app_updates", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.datetime "created_at", null: false
      t.uuid "created_by_id", null: false
      t.text "description"
      t.datetime "published_at", null: false
      t.string "title", null: false
      t.datetime "updated_at", null: false
      t.string "version", null: false
      t.index [ "created_by_id" ], name: "index_app_updates_on_created_by_id"
      t.index [ "published_at" ], name: "index_app_updates_on_published_at"
    end

    create_table "attendance_records", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid "booking_id", null: false
      t.datetime "checked_in_at"
      t.datetime "checked_out_at"
      t.datetime "created_at", null: false
      t.uuid "marked_by_id"
      t.integer "status", default: 0, null: false
      t.datetime "updated_at", null: false
      t.index [ "booking_id" ], name: "index_attendance_records_on_booking_id", unique: true
      t.index [ "marked_by_id" ], name: "index_attendance_records_on_marked_by_id"
    end

    create_table "audit_logs", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string "action", null: false
      t.uuid "auditable_id", null: false
      t.string "auditable_type", null: false
      t.uuid "company_id", null: false
      t.datetime "created_at", null: false
      t.jsonb "metadata", default: {}, null: false
      t.uuid "user_id"
      t.index [ "auditable_type", "auditable_id" ], name: "index_audit_logs_on_auditable_type_and_auditable_id"
      t.index [ "company_id", "created_at" ], name: "index_audit_logs_on_company_id_and_created_at"
      t.index [ "company_id" ], name: "index_audit_logs_on_company_id"
      t.index [ "user_id" ], name: "index_audit_logs_on_user_id"
    end

    create_table "bookings", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.decimal "amount", precision: 10, scale: 2, default: "0.0", null: false
      t.uuid "client_id", null: false
      t.uuid "contract_period_id"
      t.datetime "created_at", null: false
      t.string "currency", default: "TND", null: false
      t.integer "payment_status", default: 0, null: false
      t.uuid "session_id", null: false
      t.integer "status", default: 0, null: false
      t.datetime "updated_at", null: false
      t.integer "waitlist_position"
      t.index [ "client_id" ], name: "index_bookings_on_client_id"
      t.index [ "contract_period_id" ], name: "index_bookings_on_contract_period_id"
      t.index [ "session_id", "client_id" ], name: "index_bookings_on_session_id_and_client_id_when_held", unique: true, where: "(status = 0)"
      t.index [ "session_id", "status" ], name: "index_bookings_on_session_id_and_status"
      t.index [ "session_id", "waitlist_position" ], name: "index_bookings_waitlist_order", where: "(status = 4)"
      t.check_constraint "(status = 4) = (waitlist_position IS NOT NULL)", name: "waitlist_position_iff_waitlisted"
    end

    create_table "clients", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.boolean "active", default: true, null: false
      t.datetime "created_at", null: false
      t.string "email"
      t.datetime "email_verification_sent_at"
      t.string "email_verification_token_digest"
      t.datetime "email_verified_at"
      t.string "first_name", null: false
      t.datetime "invitation_sent_at"
      t.string "invitation_token_digest"
      t.string "last_name", null: false
      t.string "password_digest"
      t.string "phone"
      t.datetime "reset_password_sent_at"
      t.string "reset_password_token_digest"
      t.integer "token_version", default: 0, null: false
      t.datetime "updated_at", null: false
      t.index "lower((email)::text)", name: "index_clients_on_lower_email", unique: true, where: "(email IS NOT NULL)"
      t.index [ "email" ], name: "index_clients_on_email_trgm", opclass: :gin_trgm_ops, using: :gin
      t.index [ "email_verification_token_digest" ], name: "index_clients_on_email_verification_token_digest", unique: true
      t.index [ "first_name" ], name: "index_clients_on_first_name_trgm", opclass: :gin_trgm_ops, using: :gin
      t.index [ "invitation_token_digest" ], name: "index_clients_on_invitation_token_digest", unique: true
      t.index [ "last_name" ], name: "index_clients_on_last_name_trgm", opclass: :gin_trgm_ops, using: :gin
      t.index [ "phone" ], name: "index_clients_on_phone_trgm", opclass: :gin_trgm_ops, using: :gin
      t.index [ "reset_password_token_digest" ], name: "index_clients_on_reset_password_token_digest", unique: true
    end

    create_table "coaches", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.boolean "active", default: true, null: false
      t.text "bio"
      t.date "birthdate"
      t.uuid "company_id", null: false
      t.datetime "created_at", null: false
      t.string "email"
      t.string "first_name", null: false
      t.string "last_name", null: false
      t.string "phone"
      t.string "photo_url"
      t.datetime "updated_at", null: false
      t.index [ "company_id" ], name: "index_coaches_on_company_id"
    end

    create_table "companies", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.boolean "active", default: true, null: false
      t.string "address"
      t.uuid "admin_id", null: false
      t.string "city"
      t.string "country"
      t.datetime "created_at", null: false
      t.string "currency", default: "TND", null: false
      t.text "description"
      t.string "email"
      t.decimal "latitude", precision: 10, scale: 6
      t.string "locale", default: "fr", null: false
      t.decimal "longitude", precision: 10, scale: 6
      t.string "name", null: false
      t.string "phone"
      t.jsonb "settings", default: {}, null: false
      t.datetime "setup_dismissed_at"
      t.string "slug"
      t.string "timezone", default: "Africa/Tunis", null: false
      t.datetime "updated_at", null: false
      t.index [ "admin_id" ], name: "index_companies_on_admin_id"
      t.index [ "city" ], name: "index_companies_on_city_trgm", opclass: :gin_trgm_ops, using: :gin
      t.index [ "name" ], name: "index_companies_on_name_trgm", opclass: :gin_trgm_ops, using: :gin
      t.index [ "settings" ], name: "index_companies_on_settings", using: :gin
      t.index [ "slug" ], name: "index_companies_on_slug", unique: true
    end

    create_table "contract_periods", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.decimal "base_price", precision: 10, scale: 2, null: false
      t.uuid "contract_id", null: false
      t.datetime "created_at", null: false
      t.decimal "discount", precision: 10, scale: 2, default: "0.0", null: false
      t.datetime "expires_at"
      t.decimal "final_price", precision: 10, scale: 2
      t.integer "payment_status", default: 0, null: false
      t.integer "remaining_bookings"
      t.datetime "starts_at"
      t.integer "status", default: 0, null: false
      t.datetime "updated_at", null: false
      t.index [ "contract_id", "status" ], name: "index_contract_periods_on_contract_id_and_status"
      t.index [ "contract_id" ], name: "index_contract_periods_on_contract_id"
      t.index [ "status", "expires_at" ], name: "index_contract_periods_on_status_and_expires_at"
      t.check_constraint "remaining_bookings IS NULL OR remaining_bookings >= 0", name: "remaining_bookings_not_negative"
    end

    create_table "contract_type_activities", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid "activity_id", null: false
      t.uuid "contract_type_id", null: false
      t.datetime "created_at", null: false
      t.decimal "price", precision: 10, scale: 2, null: false
      t.datetime "updated_at", null: false
      t.index [ "activity_id" ], name: "index_contract_type_activities_on_activity_id"
      t.index [ "contract_type_id", "activity_id" ], name: "index_plan_activities_unique", unique: true
      t.index [ "contract_type_id" ], name: "index_contract_type_activities_on_contract_type_id"
    end

    create_table "contract_types", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.boolean "active", default: true, null: false
      t.integer "billing_period", default: 0, null: false
      t.integer "booking_limit"
      t.string "color", default: "#4f46e5", null: false
      t.uuid "company_id", null: false
      t.datetime "created_at", null: false
      t.text "description"
      t.string "name", null: false
      t.boolean "priority_booking", default: false, null: false
      t.integer "session_count"
      t.boolean "unlimited_bookings", default: false, null: false
      t.datetime "updated_at", null: false
      t.index [ "company_id" ], name: "index_contract_types_on_company_id"
      t.index [ "name" ], name: "index_contract_types_on_name_trgm", opclass: :gin_trgm_ops, using: :gin
    end

    create_table "contracts", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid "activity_id"
      t.boolean "auto_renew", default: false, null: false
      t.uuid "client_id", null: false
      t.uuid "company_id", null: false
      t.uuid "contract_type_id", null: false
      t.datetime "created_at", null: false
      t.uuid "created_by_id"
      t.datetime "updated_at", null: false
      t.index [ "activity_id" ], name: "index_contracts_on_activity_id"
      t.index [ "client_id" ], name: "index_contracts_on_client_id"
      t.index [ "company_id" ], name: "index_contracts_on_company_id"
      t.index [ "contract_type_id" ], name: "index_contracts_on_contract_type_id"
      t.index [ "created_by_id" ], name: "index_contracts_on_created_by_id"
    end

    create_table "data_imports", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid "company_id", null: false
      t.datetime "created_at", null: false
      t.integer "created_count", default: 0, null: false
      t.string "entity", null: false
      t.string "message"
      t.jsonb "row_errors", default: [], null: false
      t.integer "status", default: 0, null: false
      t.datetime "updated_at", null: false
      t.uuid "user_id"
      t.index [ "company_id" ], name: "index_data_imports_on_company_id"
      t.index [ "user_id" ], name: "index_data_imports_on_user_id"
    end

    create_table "invoice_sequences", primary_key: "year", id: :integer, default: nil do |t|
      t.integer "last_value", null: false
    end

    create_table "invoices", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.integer "amount_cents", null: false
      t.integer "billing_period", default: 0, null: false
      t.uuid "company_id", null: false
      t.datetime "created_at", null: false
      t.string "currency", null: false
      t.datetime "issued_at", null: false
      t.uuid "issued_by_id"
      t.string "notes"
      t.string "number", null: false
      t.date "period_end", null: false
      t.date "period_start", null: false
      t.boolean "trial", default: false, null: false
      t.datetime "updated_at", null: false
      t.index [ "company_id", "period_start" ], name: "index_invoices_on_company_id_and_period_start"
      t.index [ "company_id" ], name: "index_invoices_on_company_id"
      t.index [ "issued_by_id" ], name: "index_invoices_on_issued_by_id"
      t.index [ "number" ], name: "index_invoices_on_number", unique: true
    end

    create_table "memberships", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.boolean "active", default: true, null: false
      t.string "address"
      t.uuid "client_id", null: false
      t.uuid "company_id", null: false
      t.datetime "created_at", null: false
      t.date "date_of_birth"
      t.string "emergency_contact_name"
      t.string "emergency_contact_phone"
      t.string "gender"
      t.datetime "joined_at", null: false
      t.text "notes"
      t.datetime "updated_at", null: false
      t.index [ "client_id", "company_id" ], name: "index_memberships_on_client_id_and_company_id", unique: true
      t.index [ "client_id" ], name: "index_memberships_on_client_id"
      t.index [ "company_id" ], name: "index_memberships_on_company_id"
    end

    create_table "notifications", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid "company_id"
      t.datetime "created_at", null: false
      t.jsonb "data", default: {}, null: false
      t.string "dedup_key", null: false
      t.string "kind", null: false
      t.datetime "read_at"
      t.uuid "recipient_id", null: false
      t.string "recipient_type", null: false
      t.uuid "subject_id"
      t.string "subject_type"
      t.string "url", null: false
      t.index [ "company_id", "dedup_key" ], name: "index_notifications_on_company_id_and_dedup_key", unique: true
      t.index [ "company_id" ], name: "index_notifications_on_company_id"
      t.index [ "recipient_id", "created_at" ], name: "index_notifications_on_recipient_id_and_created_at"
      t.index [ "recipient_id", "read_at" ], name: "index_notifications_on_recipient_id_and_read_at"
      t.index [ "recipient_id" ], name: "index_notifications_on_recipient_id"
      t.index [ "recipient_type", "recipient_id", "created_at" ], name: "index_notifications_on_recipient_and_created_at"
      t.index [ "subject_type", "subject_id" ], name: "index_notifications_on_subject_type_and_subject_id"
    end

    create_table "payments", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.decimal "amount", precision: 10, scale: 2, null: false
      t.uuid "booking_id"
      t.uuid "client_id", null: false
      t.uuid "company_id", null: false
      t.uuid "contract_period_id"
      t.datetime "created_at", null: false
      t.uuid "created_by_id"
      t.string "currency", default: "TND", null: false
      t.text "notes"
      t.datetime "paid_at"
      t.integer "payment_method", default: 0, null: false
      t.integer "status", default: 0, null: false
      t.datetime "updated_at", null: false
      t.index [ "booking_id" ], name: "index_payments_on_booking_id"
      t.index [ "client_id" ], name: "index_payments_on_client_id"
      t.index [ "company_id", "status", "created_at" ], name: "index_payments_on_company_id_and_status_and_created_at"
      t.index [ "company_id" ], name: "index_payments_on_company_id"
      t.index [ "contract_period_id" ], name: "index_payments_on_contract_period_id"
      t.index [ "created_by_id" ], name: "index_payments_on_created_by_id"
    end

    create_table "platform_settings", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.integer "annual_discount_percent", default: 10, null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
    end

    create_table "recurring_schedules", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.boolean "active", default: true, null: false
      t.uuid "activity_id", null: false
      t.uuid "coach_id"
      t.uuid "company_id", null: false
      t.datetime "created_at", null: false
      t.date "ends_on", null: false
      t.integer "recurrence_type", default: 0, null: false
      t.time "start_time", null: false
      t.date "starts_on", null: false
      t.datetime "updated_at", null: false
      t.integer "weekdays", default: [], null: false, array: true
      t.index [ "activity_id" ], name: "index_recurring_schedules_on_activity_id"
      t.index [ "coach_id" ], name: "index_recurring_schedules_on_coach_id"
      t.index [ "company_id" ], name: "index_recurring_schedules_on_company_id"
      t.index [ "weekdays" ], name: "index_recurring_schedules_on_weekdays", using: :gin
    end

    create_table "roles", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.boolean "builtin", default: false, null: false
      t.uuid "company_id", null: false
      t.datetime "created_at", null: false
      t.string "key", null: false
      t.string "name", null: false
      t.string "permissions", default: [], null: false, array: true
      t.integer "position", default: 0, null: false
      t.integer "staff_members_count", default: 0, null: false
      t.datetime "updated_at", null: false
      t.index [ "company_id", "key" ], name: "index_roles_on_company_id_and_key", unique: true
      t.index [ "company_id" ], name: "index_roles_on_company_id"
    end

    create_table "sessions", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid "activity_id", null: false
      t.integer "capacity", null: false
      t.uuid "coach_id"
      t.uuid "company_id", null: false
      t.datetime "created_at", null: false
      t.datetime "ends_at", null: false
      t.decimal "price", precision: 10, scale: 2, default: "0.0", null: false
      t.uuid "recurring_schedule_id"
      t.uuid "space_id"
      t.datetime "starts_at", null: false
      t.integer "status", default: 0, null: false
      t.datetime "updated_at", null: false
      t.index [ "activity_id" ], name: "index_sessions_on_activity_id"
      t.index [ "coach_id", "starts_at" ], name: "index_sessions_on_coach_id_and_starts_at"
      t.index [ "company_id" ], name: "index_sessions_on_company_id"
      t.index [ "recurring_schedule_id" ], name: "index_sessions_on_recurring_schedule_id"
      t.index [ "space_id" ], name: "index_sessions_on_space_id"
      t.exclusion_constraint "coach_id WITH =, tsrange(starts_at, ends_at) WITH &&", where: "(status = 0) AND (coach_id IS NOT NULL)", using: :gist, name: "no_overlapping_coach_sessions"
      t.exclusion_constraint "space_id WITH =, tsrange(starts_at, ends_at) WITH &&", where: "(status = 0) AND (space_id IS NOT NULL)", using: :gist, name: "no_overlapping_space_sessions"
    end

    create_table "spaces", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.boolean "active", default: true, null: false
      t.integer "capacity"
      t.uuid "company_id", null: false
      t.datetime "created_at", null: false
      t.string "kind"
      t.string "name", null: false
      t.jsonb "settings", default: {}, null: false
      t.datetime "updated_at", null: false
      t.index [ "company_id", "name" ], name: "index_spaces_on_company_id_and_name", unique: true
      t.index [ "company_id" ], name: "index_spaces_on_company_id"
      t.index [ "name" ], name: "index_spaces_on_name_trgm", opclass: :gin_trgm_ops, using: :gin
      t.check_constraint "capacity IS NULL OR capacity > 0", name: "spaces_capacity_positive"
    end

    create_table "staff_members", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.boolean "active", default: true, null: false
      t.date "birthdate"
      t.uuid "coach_id"
      t.uuid "company_id", null: false
      t.datetime "created_at", null: false
      t.uuid "role_id", null: false
      t.datetime "updated_at", null: false
      t.uuid "user_id", null: false
      t.index [ "coach_id" ], name: "index_staff_members_on_coach_id"
      t.index [ "company_id" ], name: "index_staff_members_on_company_id"
      t.index [ "role_id" ], name: "index_staff_members_on_role_id"
      t.index [ "user_id" ], name: "index_staff_members_on_user_id", unique: true
    end

    create_table "subscription_prices", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.integer "company_limit", default: 1, null: false
      t.datetime "created_at", null: false
      t.string "currency", null: false
      t.integer "monthly_cents", default: 0, null: false
      t.datetime "updated_at", null: false
      t.index [ "currency", "company_limit" ], name: "index_subscription_prices_on_currency_and_tier", unique: true
    end

    create_table "subscriptions", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.boolean "active", default: true, null: false
      t.integer "billing_period"
      t.uuid "company_id", null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index [ "company_id" ], name: "index_subscriptions_on_company_id", unique: true
    end

    create_table "support_tickets", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid "company_id", null: false
      t.string "contact_phone"
      t.datetime "created_at", null: false
      t.uuid "created_by_id", null: false
      t.integer "kind", default: 0, null: false
      t.text "message", null: false
      t.integer "status", default: 0, null: false
      t.string "subject", null: false
      t.datetime "updated_at", null: false
      t.index [ "company_id" ], name: "index_support_tickets_on_company_id"
      t.index [ "created_by_id" ], name: "index_support_tickets_on_created_by_id"
      t.index [ "status" ], name: "index_support_tickets_on_status"
    end

    create_table "users", id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.boolean "active", default: true, null: false
      t.uuid "active_company_id"
      t.integer "company_limit", default: 1
      t.datetime "created_at", null: false
      t.string "email", null: false
      t.datetime "email_verification_sent_at"
      t.string "email_verification_token_digest"
      t.datetime "email_verified_at"
      t.string "first_name", null: false
      t.string "last_name", null: false
      t.string "locale", default: "fr", null: false
      t.string "password_digest", null: false
      t.string "phone"
      t.datetime "reset_password_sent_at"
      t.string "reset_password_token_digest"
      t.integer "role", default: 1, null: false
      t.integer "token_version", default: 0, null: false
      t.datetime "updated_at", null: false
      t.index [ "active_company_id" ], name: "index_users_on_active_company_id"
      t.index [ "email" ], name: "index_users_on_email", unique: true
      t.index [ "email" ], name: "index_users_on_email_trgm", opclass: :gin_trgm_ops, using: :gin
      t.index [ "email_verification_token_digest" ], name: "index_users_on_email_verification_token_digest", unique: true
      t.index [ "first_name" ], name: "index_users_on_first_name_trgm", opclass: :gin_trgm_ops, using: :gin
      t.index [ "last_name" ], name: "index_users_on_last_name_trgm", opclass: :gin_trgm_ops, using: :gin
      t.index [ "reset_password_token_digest" ], name: "index_users_on_reset_password_token_digest", unique: true
    end

    add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
    add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
    add_foreign_key "activities", "companies"
    add_foreign_key "activity_spaces", "activities"
    add_foreign_key "activity_spaces", "spaces"
    add_foreign_key "app_updates", "users", column: "created_by_id"
    add_foreign_key "attendance_records", "bookings"
    add_foreign_key "attendance_records", "users", column: "marked_by_id"
    add_foreign_key "audit_logs", "companies"
    add_foreign_key "audit_logs", "users"
    add_foreign_key "bookings", "clients"
    add_foreign_key "bookings", "contract_periods"
    add_foreign_key "bookings", "sessions"
    add_foreign_key "coaches", "companies"
    add_foreign_key "companies", "users", column: "admin_id"
    add_foreign_key "contract_periods", "contracts"
    add_foreign_key "contract_type_activities", "activities"
    add_foreign_key "contract_type_activities", "contract_types"
    add_foreign_key "contract_types", "companies"
    add_foreign_key "contracts", "activities"
    add_foreign_key "contracts", "clients"
    add_foreign_key "contracts", "companies"
    add_foreign_key "contracts", "contract_types"
    add_foreign_key "contracts", "users", column: "created_by_id"
    add_foreign_key "data_imports", "companies"
    add_foreign_key "data_imports", "users"
    add_foreign_key "invoices", "companies"
    add_foreign_key "invoices", "users", column: "issued_by_id"
    add_foreign_key "memberships", "clients"
    add_foreign_key "memberships", "companies"
    add_foreign_key "notifications", "companies"
    add_foreign_key "payments", "bookings"
    add_foreign_key "payments", "clients"
    add_foreign_key "payments", "companies"
    add_foreign_key "payments", "contract_periods"
    add_foreign_key "payments", "users", column: "created_by_id"
    add_foreign_key "recurring_schedules", "activities"
    add_foreign_key "recurring_schedules", "coaches"
    add_foreign_key "recurring_schedules", "companies"
    add_foreign_key "roles", "companies"
    add_foreign_key "sessions", "activities"
    add_foreign_key "sessions", "coaches"
    add_foreign_key "sessions", "companies"
    add_foreign_key "sessions", "recurring_schedules"
    add_foreign_key "sessions", "spaces"
    add_foreign_key "spaces", "companies"
    add_foreign_key "staff_members", "coaches"
    add_foreign_key "staff_members", "companies"
    add_foreign_key "staff_members", "roles"
    add_foreign_key "staff_members", "users"
    add_foreign_key "subscriptions", "companies"
    add_foreign_key "support_tickets", "companies"
    add_foreign_key "support_tickets", "users", column: "created_by_id"
    add_foreign_key "users", "companies", column: "active_company_id", on_delete: :nullify
  end
end
