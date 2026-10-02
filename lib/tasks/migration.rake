# The Phase 9 rehearsal, as two commands.
#
#   BEFORE the migrations, on a restored copy of production:
#     bin/rails migration:snapshot
#   THEN:
#     bin/rails db:migrate
#     bin/rails migration:verify
#
# Both are read-only apart from the snapshot file. `verify` exits non-zero
# on any failure, so it can gate a deploy.
#
# See docs/MIGRATION_PLAN.md §2 and §9.
namespace :migration do
  DEFAULT_SNAPSHOT = "tmp/migration_snapshot.json".freeze

  desc "Record row counts before migrating (path: SNAPSHOT=tmp/migration_snapshot.json)"
  task snapshot: :environment do
    path = ENV.fetch("SNAPSHOT", DEFAULT_SNAPSHOT)
    counts = Migration::Audit.new.row_counts

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(
      "taken_at" => Time.current.iso8601,
      "database" => ActiveRecord::Base.connection_db_config.database,
      "counts" => counts
    ))

    puts "#{counts.values.sum} rows across #{counts.size} tables → #{path}"
  end

  desc "Audit a migrated database against the snapshot and the invariants"
  task verify: :environment do
    path = ENV.fetch("SNAPSHOT", DEFAULT_SNAPSHOT)
    before = File.exist?(path) ? JSON.parse(File.read(path)).fetch("counts", {}) : {}

    puts "Database: #{ActiveRecord::Base.connection_db_config.database}"
    puts before.empty? ? "No snapshot at #{path} — counts recorded, not compared." : "Snapshot: #{path}"
    puts

    result = Migration::Audit.call(before: before)

    result[:findings].each do |finding|
      mark = finding.ok? ? "ok  " : "FAIL"
      puts "  #{mark}  #{finding.check}#{finding.detail ? " — #{finding.detail}" : ''}"
    end

    puts
    result[:counts].sort_by { |table, count| [ -count, table ] }.each do |table, count|
      was = before[table]
      change = was && was != count ? " (was #{was})" : ""
      puts format("  %-28s %8d%s", table, count, change)
    end

    puts
    if result[:ok]
      puts "Every check passed. Safe to run the same migrations against production."
    else
      failed = result[:findings].reject(&:ok?)
      abort "#{failed.size} check(s) failed. Do not migrate production until each is understood."
    end
  end
end

namespace :migration do
  desc "Read every tenant back through the app's own services (per shell)"
  task spot_check: :environment do
    failures = []

    Company.includes(admin: :subscription).find_each do |company|
      label = "#{company.name} (#{company.id})"
      reads = {
        # Admin shell: the dashboard is the widest read in the product —
        # members, contracts, today's schedule, money and the attention list
        # in one call.
        "admin dashboard" => -> { Dashboard::Statistics.call(company: company) },
        # What the shell itself is built from.
        "company payload" => -> { CompanySerializer.new(company).as_json },
        "branding" => -> { CompanyBrandingSerializer.new(company).as_json },
        "settings" => -> { company.settings.to_h },
        "setup flow" => -> { company.onboarding_state.as_json },
        "admin permissions" => -> { company.admin.permission_keys },
        # Desk / coach: the schedule, and the roster behind it.
        "schedule" => -> { company.sessions.includes(:activity, :coach, :space).limit(50).map { |s| SessionSerializer.new(s).as_json } },
        "team" => -> { company.staff_members.includes(:user, :role).map { |s| StaffMemberSerializer.new(s).as_json } },
        # Member: their own file, which is what a migrated contract has to
        # still add up to.
        "members" => -> { company.memberships.includes(:client).limit(50).map { |m| ClientSerializer.new(m.client, company: company).as_json } },
        "contracts" => -> { company.contracts.includes(:contract_type, :activity, :client).limit(50).map { |c| ContractSerializer.new(c).as_json } }
      }

      results = reads.map do |what, read|
        read.call
        "ok"
      rescue StandardError => e
        failures << "#{label} — #{what}: #{e.class}: #{e.message}"
        "FAIL"
      end

      puts "  #{results.include?('FAIL') ? 'FAIL' : 'ok  '}  #{label}"
    end

    puts
    if failures.empty?
      puts "Every company reads correctly in every shell."
    else
      failures.each { |f| puts "  #{f}" }
      abort "#{failures.size} read(s) failed."
    end
  end
end
