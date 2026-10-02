module Migration
  # What must be true of a database after the Phase 3 migrations have run.
  #
  # Written to be run against a RESTORED PRODUCTION DUMP before the same
  # migrations are run against production itself, and again against
  # production afterwards. It reads with plain SQL and never through the
  # models: a model can only describe the schema it was written for, and
  # the whole point is to find out whether the database agrees.
  #
  # It writes nothing. Running it on production is safe.
  class Audit
    Finding = Struct.new(:check, :detail, :ok, keyword_init: true) do
      def ok? = ok
    end

    # Tables the migrations touch, plus everything that hangs off them.
    # Counted before and after: a migration that loses a member is a
    # migration that must not reach production.
    COUNTED_TABLES = %w[
      companies users staff_members roles clients memberships coaches
      activities spaces activity_spaces sessions recurring_schedules
      bookings attendance_records contract_types contract_type_activities
      contracts contract_periods payments invoices subscriptions
      subscription_prices platform_settings audit_logs notifications
      support_tickets app_updates
    ].freeze

    # Columns the destructive migrations drop. Still present means the
    # migration did not run; that is worth saying out loud rather than
    # letting a later check fail confusingly.
    DROPPED_COLUMNS = {
      "companies" => %w[business_hours_start business_hours_end working_days primary_color locations_count],
      "staff_members" => %w[role],
      # Each gym's copy of a member's details moved onto the membership.
      "clients" => %w[date_of_birth gender address emergency_contact_name emergency_contact_phone]
    }.freeze

    ADDED_COLUMNS = {
      "companies" => %w[settings],
      "sessions" => %w[space_id],
      "bookings" => %w[waitlist_position],
      "memberships" => %w[date_of_birth gender address emergency_contact_name emergency_contact_phone],
      "clients" => %w[token_version invitation_token_digest invitation_sent_at]
    }.freeze

    REQUIRED_CONSTRAINTS = %w[
      no_overlapping_coach_sessions
      no_overlapping_space_sessions
      waitlist_position_iff_waitlisted
      spaces_capacity_positive
      remaining_bookings_not_negative
    ].freeze

    def self.call(before: nil)
      new(before: before).call
    end

    def initialize(before: nil)
      @before = before || {}
      @findings = []
    end

    # => { ok:, counts:, findings: [Finding] }
    def call
      counts = row_counts

      check_counts(counts)
      check_schema
      check_settings
      check_staff_roles
      check_orphans
      check_tenant_leakage

      { ok: @findings.all?(&:ok?), counts: counts, findings: @findings }
    end

    # Usable on the OLD schema too — that is the point of taking it before
    # the migrations run. Silently skips a table the database does not have,
    # so one snapshot format covers both sides.
    def row_counts
      existing = tables
      COUNTED_TABLES.select { |t| existing.include?(t) }.index_with do |table|
        connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i
      end
    end

    private

    def connection = ActiveRecord::Base.connection

    def tables
      @tables ||= connection.tables.to_set
    end

    def columns(table)
      return Set.new unless tables.include?(table)

      connection.columns(table).map(&:name).to_set
    end

    def note(check, ok, detail = nil)
      @findings << Finding.new(check: check, ok: ok, detail: detail)
    end

    # A row present before and absent after is data loss. Growth is fine —
    # a rehearsal on a live copy may pick up writes — so only shrinkage is
    # a failure.
    def check_counts(after)
      return note("row counts", true, "no baseline given; counts recorded only") if @before.empty?

      lost = @before.filter_map do |table, was|
        now = after[table]
        next if now.nil? || now >= was

        "#{table}: #{was} → #{now}"
      end

      note("row counts", lost.empty?, lost.empty? ? "#{after.values.sum} rows across #{after.size} tables" : lost.join(", "))
    end

    def check_schema
      DROPPED_COLUMNS.each do |table, cols|
        left = columns(table) & cols.to_set
        note("#{table}: dropped columns gone", left.empty?, left.to_a.join(", ").presence)
      end

      ADDED_COLUMNS.each do |table, cols|
        missing = cols.to_set - columns(table)
        note("#{table}: new columns present", missing.empty?, missing.to_a.join(", ").presence)
      end

      present = connection.select_values(<<~SQL).to_set
        SELECT conname FROM pg_constraint
        UNION
        SELECT indexname FROM pg_indexes WHERE schemaname = 'public'
      SQL
      missing = REQUIRED_CONSTRAINTS.to_set - present
      note("constraints in place", missing.empty?, missing.to_a.join(", ").presence)
    end

    # The settings backfill is the one migration that could quietly leave a
    # company without opening hours, which would then read as "closed every
    # day" across the whole calendar.
    def check_settings
      return note("settings backfilled", false, "companies.settings is missing") unless columns("companies").include?("settings")

      incomplete = connection.select_values(<<~SQL)
        SELECT id::text FROM companies
        WHERE settings #>> '{hours,start}' IS NULL
           OR settings #>> '{hours,end}' IS NULL
           OR jsonb_typeof(settings #> '{hours,working_days}') <> 'array'
      SQL
      note("settings backfilled", incomplete.empty?, incomplete.first(5).join(", ").presence)

      # Nothing should be storing keys the code does not declare — that is
      # how a settings column turns into a junk drawer.
      unknown = connection.select_values(<<~SQL)
        SELECT DISTINCT key FROM companies, jsonb_object_keys(settings) AS key
      SQL
      strays = unknown.map(&:to_s) - CompanySettings::SECTIONS.map(&:to_s)
      note("settings has no stray sections", strays.empty?, strays.join(", ").presence)
    end

    def check_staff_roles
      return note("every staff member has a role", false, "staff_members.role_id is missing") unless columns("staff_members").include?("role_id")

      roleless = connection.select_value("SELECT COUNT(*) FROM staff_members WHERE role_id IS NULL").to_i
      note("every staff member has a role", roleless.zero?, roleless.positive? ? "#{roleless} without one" : nil)
    end

    # A row pointing at a parent that is not there. Foreign keys make most of
    # these impossible; the ones worth checking are where a migration
    # nullified or rewrote a reference.
    ORPHAN_CHECKS = {
      "sessions in a room that is gone" =>
        "SELECT COUNT(*) FROM sessions s LEFT JOIN spaces sp ON sp.id = s.space_id WHERE s.space_id IS NOT NULL AND sp.id IS NULL",
      "payments on a period that is gone" =>
        "SELECT COUNT(*) FROM payments p LEFT JOIN contract_periods cp ON cp.id = p.contract_period_id " \
        "WHERE p.contract_period_id IS NOT NULL AND cp.id IS NULL",
      "contracts on a plan that is gone" =>
        "SELECT COUNT(*) FROM contracts c LEFT JOIN contract_types ct ON ct.id = c.contract_type_id WHERE ct.id IS NULL",
      "contracts for an activity that is gone" =>
        "SELECT COUNT(*) FROM contracts c LEFT JOIN activities a ON a.id = c.activity_id WHERE c.activity_id IS NOT NULL AND a.id IS NULL",
      "bookings on a session that is gone" =>
        "SELECT COUNT(*) FROM bookings b LEFT JOIN sessions s ON s.id = b.session_id WHERE s.id IS NULL",
      "staff seats on a role that is gone" =>
        "SELECT COUNT(*) FROM staff_members sm LEFT JOIN roles r ON r.id = sm.role_id WHERE sm.role_id IS NOT NULL AND r.id IS NULL"
    }.freeze

    def check_orphans
      ORPHAN_CHECKS.each do |label, sql|
        next unless runnable?(sql)

        count = connection.select_value(sql).to_i
        note(label, count.zero?, count.positive? ? "#{count} row(s)" : nil)
      end
    end

    # The check that matters most and that no foreign key makes: a row in one
    # company reaching a row in another. A booking, a session and a contract
    # each join across three tables, and a migration that rewrote one of
    # those references is exactly where a tenant boundary would break.
    LEAKAGE_CHECKS = {
      "sessions use their own company's activity" =>
        "SELECT COUNT(*) FROM sessions s JOIN activities a ON a.id = s.activity_id WHERE a.company_id <> s.company_id",
      "sessions use their own company's room" =>
        "SELECT COUNT(*) FROM sessions s JOIN spaces sp ON sp.id = s.space_id WHERE sp.company_id <> s.company_id",
      "contracts use their own company's plan" =>
        "SELECT COUNT(*) FROM contracts c JOIN contract_types ct ON ct.id = c.contract_type_id WHERE ct.company_id <> c.company_id",
      "contracts use their own company's activity" =>
        "SELECT COUNT(*) FROM contracts c JOIN activities a ON a.id = c.activity_id WHERE a.company_id <> c.company_id",
      "a plan is only priced for its own activities" =>
        "SELECT COUNT(*) FROM contract_type_activities cta JOIN contract_types ct ON ct.id = cta.contract_type_id " \
        "JOIN activities a ON a.id = cta.activity_id WHERE a.company_id <> ct.company_id",
      "a room is only restricted to its own activities" =>
        "SELECT COUNT(*) FROM activity_spaces asp JOIN spaces sp ON sp.id = asp.space_id " \
        "JOIN activities a ON a.id = asp.activity_id WHERE a.company_id <> sp.company_id",
      "bookings belong to a member of that gym" =>
        "SELECT COUNT(*) FROM bookings b JOIN sessions s ON s.id = b.session_id " \
        "LEFT JOIN memberships m ON m.client_id = b.client_id AND m.company_id = s.company_id WHERE m.id IS NULL",
      "payments settle their own company's contract" =>
        "SELECT COUNT(*) FROM payments p JOIN contract_periods cp ON cp.id = p.contract_period_id " \
        "JOIN contracts c ON c.id = cp.contract_id WHERE c.company_id <> p.company_id",
      "payments belong to a member of that gym" =>
        "SELECT COUNT(*) FROM payments p LEFT JOIN memberships m ON m.client_id = p.client_id AND m.company_id = p.company_id " \
        "WHERE p.client_id IS NOT NULL AND m.id IS NULL",
      "staff hold a role from their own company" =>
        "SELECT COUNT(*) FROM staff_members sm JOIN roles r ON r.id = sm.role_id WHERE r.company_id <> sm.company_id"
    }.freeze

    def check_leakage_query(label, sql)
      count = connection.select_value(sql).to_i
      note(label, count.zero?, count.positive? ? "#{count} row(s) cross a tenant boundary" : nil)
    end

    def check_tenant_leakage
      LEAKAGE_CHECKS.each do |label, sql|
        next unless runnable?(sql)

        check_leakage_query(label, sql)
      end
    end

    # A query naming a table this database does not have is skipped rather
    # than raised: the snapshot side runs on the old schema too.
    def runnable?(sql)
      sql.scan(/(?:FROM|JOIN)\s+(\w+)/i).flatten.uniq.all? { |t| tables.include?(t) }
    end
  end
end
