# Fixtures for the Playwright smoke suite (frontend/e2e/). Runs against its
# own database, never the one you develop on:
#
#   DATABASE_URL=postgres:///backend_e2e bin/rails db:prepare e2e:seed
#
# Empties every table, then writes one gym with an admin, an activity, a
# plan, a class tomorrow, and a member holding an invitation. Credentials and
# the invitation token go to tmp/e2e.json for the tests to read.
namespace :e2e do
  desc "Reset the e2e database to the smoke-suite fixtures (DATABASE_URL must name a *_e2e database)"
  task seed: :environment do
    database = ActiveRecord::Base.connection_db_config.database.to_s
    abort("Refusing to seed #{database.inspect}: the e2e seed only runs on a database named *_e2e.") unless database.end_with?("_e2e")

    connection = ActiveRecord::Base.connection
    tables = connection.tables - %w[schema_migrations ar_internal_metadata]
    connection.execute("TRUNCATE #{tables.map { |t| connection.quote_table_name(t) }.join(', ')} RESTART IDENTITY CASCADE")

    password = "e2e-password-1"
    admin = User.create!(
      first_name: "Olfa", last_name: "Admin", email: "admin@e2e.test", password: password,
      role: :admin, locale: "fr", email_verified_at: Time.current
    )
    company = Company.open!(
      admin: admin,
      attributes: { name: "Salle E2E", currency: "TND", timezone: "Africa/Tunis", locale: "fr" }
    )
    # Straight to the dashboard, not the first-run setup flow.
    company.update!(setup_dismissed_at: Time.current)

    yoga = company.activities.create!(name: "Yoga", session_format: :collective, capacity: 12, duration: 60)
    plan = company.contract_types.create!(name: "Mensuel", billing_period: :monthly, unlimited_bookings: true)
    plan.contract_type_activities.create!(activity: yoga, price: 90)

    member = Client.create!(first_name: "Salma", last_name: "Member", phone: "+216 20 111 111", email: "member@e2e.test")
    member.join!(company)
    Contract.sell!(client: member, contract_type: plan, activity: yoga, created_by: admin)
    invitation_token = member.generate_invitation_token!

    starts_at = company.time_zone.now.tomorrow.change(hour: 18)
    company.sessions.create!(
      activity: yoga, starts_at: starts_at, ends_at: starts_at + 1.hour, capacity: 12, status: :scheduled
    )

    fixtures = {
      admin: { email: admin.email, password: password },
      member: { email: member.email, invitation_token: invitation_token, name: member.full_name },
      gym: { name: company.name, activity: yoga.name, plan: plan.name }
    }
    FileUtils.mkdir_p(Rails.root.join("tmp"))
    File.write(Rails.root.join("tmp/e2e.json"), JSON.pretty_generate(fixtures))
    puts "e2e fixtures written to tmp/e2e.json"
  end
end
