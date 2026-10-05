# Seeds a realistic multi-company dataset for the k6 load test in
# load_test/ — companies with staff/coaches/activities, upcoming bookable
# sessions, and real loginable clients (each with an active, unlimited-
# bookings contract so a booking attempt is never rejected on eligibility
# grounds, only on capacity/duplicate checks like production traffic would
# hit).
#
# Company-level setup mirrors what Api::V1::CompaniesController#create does
# on a real signup (role defaults, subscription, one location, work
# contract/absence type defaults) — through real ActiveRecord so it stays
# correct if that flow changes. Clients/sessions/contracts are bulk
# `insert_all`, since those are the volume: every client shares ONE
# pre-computed bcrypt digest (has_secure_password just compares digests, so
# reusing one is safe) rather than paying bcrypt's deliberately-expensive
# hash cost per row.
#
#   bin/rails load_test:seed                                  # 5 companies x 300 clients x 40 sessions
#   COMPANIES=20 CLIENTS_PER_COMPANY=1000 bin/rails load_test:seed
#   bin/rails load_test:clear                                  # remove it all again
namespace :load_test do
  desc "Seed a multi-company dataset (staff, coaches, sessions, loginable clients with contracts) for k6"
  task seed: :environment do
    companies_count      = Integer(ENV.fetch("COMPANIES", 5))
    clients_per_company  = Integer(ENV.fetch("CLIENTS_PER_COMPANY", 300))
    sessions_per_company = Integer(ENV.fetch("SESSIONS_PER_COMPANY", 40))
    password              = ENV.fetch("LOAD_TEST_PASSWORD", "loadtest123")
    password_digest       = BCrypt::Password.create(password)

    accounts = {
      base_url: ENV.fetch("LOAD_TEST_BASE_URL", "http://localhost:3000"),
      password: password,
      admins: [],
      clients: []
    }

    started = Time.current

    companies_count.times do |i|
      admin = User.create!(
        first_name: "Admin", last_name: i.to_s,
        email: "loadtest-admin-#{i}@fitora.load",
        password: password, role: :admin, locale: "fr",
        # An unconfirmed admin reaches nothing (BaseController#require_confirmed_email!).
        email_verified_at: Time.current
      )

      company = Company.new(name: "Load Test Gym #{i}", timezone: "Africa/Tunis", currency: "TND", locale: "fr")
      company.admin = admin
      company.save!
      admin.update!(active_company: company)

      Role.seed_defaults_for(company)
      company.admin.subscription || company.admin.create_subscription!(active: true, billing_period: :monthly, plan: :pro)
      location = company.locations.create!(name: company.name, timezone: company.timezone)

      activities = 6.times.map do |a|
        Activity.create!(location: location, name: "Activity #{i}-#{a}", session_format: :collective, duration: 60, capacity: 15)
      end

      coaches = 4.times.map { |c| Coach.create!(company: company, first_name: "Coach", last_name: "#{i}-#{c}") }
      coaches.each { |coach| CoachLocation.create!(coach: coach, location: location) }

      plan = ContractType.create!(
        company: company, name: "Load Test Unlimited", billing_period: :monthly, unlimited_bookings: true
      )
      # The plan is sold per activity now, so it needs a tariff for each one.
      activities.each { |activity| plan.contract_type_activities.create!(activity: activity, price: 89) }

      now = Time.current
      slots = [ 7, 9, 12, 17, 18, 19, 20 ]
      session_rows = sessions_per_company.times.map do |s|
        starts_at = (s % 10).days.from_now.change(hour: slots.sample, min: 0)
        {
          id: SecureRandom.uuid, activity_id: activities.sample.id, location_id: location.id,
          coach_id: coaches.sample.id, capacity: [ 8, 10, 12, 15, 20 ].sample, price: 20, status: 0,
          starts_at: starts_at, ends_at: starts_at + 60.minutes, created_at: now, updated_at: now
        }
      end
      Session.insert_all(session_rows)

      client_rows = clients_per_company.times.map do |c|
        {
          id: SecureRandom.uuid, company_id: company.id, first_name: "Client", last_name: "#{i}-#{c}",
          email: "loadtest-client-#{i}-#{c}@fitora.load", phone: "+216 2#{format('%07d', c)}",
          password_digest: password_digest, active: true, joined_at: now, created_at: now, updated_at: now
        }
      end
      Client.insert_all(client_rows)

      contract_rows = client_rows.each_with_index.map do |c, n|
        { id: SecureRandom.uuid, client_id: c[:id], contract_type_id: plan.id, activity_id: activities.sample.id,
          # insert_all skips Contract#assign_invoice_ref, so the reference is spelled out here.
          invoice_ref: format("FAC-%<year>d-%<n>04d", year: now.year, n: n + 1),
          company_id: company.id, status: 1, payment_status: 1,
          starts_at: 1.day.ago, expires_at: 1.year.from_now, discount: 0, base_price: 89, final_price: 89,
          created_at: now, updated_at: now }
      end
      Contract.insert_all(contract_rows)

      accounts[:admins] << { email: admin.email, company_id: company.id, company_name: company.name }
      accounts[:clients].concat(client_rows.map { |c| { email: c[:email], company_id: company.id } })

      puts "  [#{i + 1}/#{companies_count}] #{company.name}: #{clients_per_company} clients, #{sessions_per_company} sessions"
    end

    out_dir = Rails.root.join("load_test/data")
    FileUtils.mkdir_p(out_dir)
    out_file = out_dir.join("accounts.json")
    File.write(out_file, JSON.pretty_generate(accounts))

    elapsed = (Time.current - started).round(1)
    puts "Done in #{elapsed}s — #{accounts[:admins].size} admins, #{accounts[:clients].size} clients. Wrote #{out_file}"
  end

  desc "Remove all load-test seeded data"
  task clear: :environment do
    count = 0
    User.where("email LIKE 'loadtest-admin-%@fitora.load'").find_each do |admin|
      admin.destroy # dependent: :destroy on User#companies takes every one of them with it
      count += 1
    end
    puts "Cleared #{count} load-test companies and everything under them."
  end
end
