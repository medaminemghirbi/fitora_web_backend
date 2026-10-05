# Proves a backup restores — the half of backing up that usually never gets
# done. Nightly dumps come from the `backup` accessory (config/deploy.yml);
# this takes one of them, restores it into a scratch database next to the
# real one, reads it back, and drops the scratch copy.
#
#   bin/rails backup:restore_check FILE=backup.dump
#   bin/rails backup:restore_check FILE=backup.dump.gpg   # needs PASSPHRASE
#
# Exits non-zero if the restore fails, the database comes back empty, or the
# invariants Migration::Audit checks (orphans, cross-tenant references,
# constraints) do not hold. Never touches the database the app is using.
namespace :backup do
  desc "Restore a dump into a scratch database and check it (FILE=path)"
  task restore_check: :environment do
    file = ENV["FILE"].presence or abort("Give the dump to check: FILE=path/to/backup.dump")
    abort("No such file: #{file}") unless File.exist?(file)

    config = ActiveRecord::Base.connection_db_config.configuration_hash
    scratch = "fitora_restore_check_#{Time.current.strftime('%Y%m%d%H%M%S')}"
    pg_env = {
      "PGHOST" => config[:host].to_s, "PGPORT" => config[:port].to_s,
      "PGUSER" => config[:username].to_s, "PGPASSWORD" => config[:password].to_s
    }.reject { |_, v| v.empty? }

    dump = file
    if file.end_with?(".gpg")
      passphrase = ENV["PASSPHRASE"].presence or abort("#{file} is encrypted: set PASSPHRASE.")
      dump = Rails.root.join("tmp", "#{scratch}.dump").to_s
      ok = system("gpg", "--batch", "--yes", "--quiet", "--passphrase", passphrase, "--output", dump, "--decrypt", file)
      abort("Could not decrypt #{file}.") unless ok
    end

    system(pg_env, "createdb", scratch, exception: true)
    begin
      # --no-admin: the dump's roles need not exist here.
      restored = system(pg_env, "pg_restore", "--no-admin", "--no-privileges", "--dbname", scratch, dump)
      abort("pg_restore failed on #{file}.") unless restored

      ActiveRecord::Base.establish_connection(config.merge(database: scratch))
      result = Migration::Audit.call(before: {})
      counts = result[:counts]

      puts "Restored #{file} into #{scratch}: #{counts.values.sum} rows across #{counts.size} tables."
      result[:findings].each do |finding|
        puts "  #{finding.ok? ? 'ok  ' : 'FAIL'}  #{finding.check}#{finding.detail ? " — #{finding.detail}" : ''}"
      end

      abort("The restored database is empty.") if counts.values.sum.zero?
      abort("The restored database fails its invariants — see above.") unless result[:ok]

      puts "This backup restores."
    ensure
      ActiveRecord::Base.establish_connection(config)
      system(pg_env, "dropdb", "--if-exists", scratch)
      File.delete(dump) if dump != file && File.exist?(dump)
    end
  end
end
