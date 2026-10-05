module Demo
  # Studio Lumen, La Marsa — a private studio to demo the product on: two
  # EMS cabins, a Reformer studio, a yoga room, four coaches, twenty members
  # with three months of history, contracts renewed as chains, a member on
  # hold and a prospect booked on a trial. Shared by the two demo tasks
  # (lib/tasks/demo.rake), which only differ in what they clear first.
  class StudioLumen
    ADMIN_EMAIL = "meriem@studiolumen.tn".freeze
    PASSWORD = "demo-lumen-2026".freeze

    # Builds the studio and returns the logins worth handing out.
    def self.build!
      password = PASSWORD
      srand(42)

      admin = User.create!(
        first_name: "Meriem", last_name: "Ben Ammar", email: ADMIN_EMAIL, password: password,
        role: :admin, locale: "fr", email_verified_at: Time.current
      )
      company = Company.open!(
        admin: admin,
        attributes: {
          name: "Studio Lumen", currency: "TND", timezone: "Africa/Tunis", locale: "fr",
          city: "La Marsa", country: "TN", address: "12 rue Habib Thameur, La Marsa",
          phone: "+216 71 774 200", email: "bonjour@studiolumen.tn"
        }
      )
      company.update!(
        setup_dismissed_at: Time.current,
        signatory_name: "Meriem Ben Ammar, gérante",
        settings: {
          features: { spaces: true, waitlist: true, drop_in: true },
          booking: { cancellation_hours: 12, booking_opens_days: 14, reminder_hours: 24 },
          hours: { start: "07:00", end: "21:00", working_days: [ 1, 2, 3, 4, 5, 6 ] }
        }
      )
      zone = company.time_zone

      # ---- what the studio sells -------------------------------------------
      ems = company.activities.create!(name: "EMS", emoji: "⚡", activity_template: ActivityTemplate.find_by(key: "ems"), session_format: :individual, capacity: 1, duration: 25,
                                        description: "Électrostimulation, 25 minutes en cabine avec un coach.")
      coaching = company.activities.create!(name: "Coaching privé", emoji: "🏋️", activity_template: ActivityTemplate.find_by(key: "coaching_prive"), session_format: :individual, capacity: 1, duration: 60,
                                             description: "Séance individuelle sur programme personnalisé.")
      reformer = company.activities.create!(name: "Pilates Reformer", emoji: "🌀", activity_template: ActivityTemplate.find_by(key: "pilates_reformer"), session_format: :small_group, capacity: 6, duration: 50)
      yoga = company.activities.create!(name: "Yoga Vinyasa", emoji: "🧘", activity_template: ActivityTemplate.find_by(key: "yoga"), session_format: :collective, capacity: 14, duration: 60)

      cabin1 = company.spaces.create!(name: "Cabine EMS 1", kind: "cabine", capacity: 1)
      cabin2 = company.spaces.create!(name: "Cabine EMS 2", kind: "cabine", capacity: 1)
      reformer_room = company.spaces.create!(name: "Studio Reformer", kind: "studio", capacity: 6)
      yoga_room = company.spaces.create!(name: "Studio Yoga", kind: "studio", capacity: 14)

      plans = {}
      plans[:ems10] = company.contract_types.create!(name: "Carnet EMS 10 séances", billing_period: :custom, validity_days: 56,
                                                     unlimited_bookings: false, session_count: 10, booking_limit: 10, color: "#6d28d9",
                                                     description: "10 séances de 25 min, valables 8 semaines.")
      plans[:ems10].contract_type_activities.create!(activity: ems, price: 450)
      plans[:pt5] = company.contract_types.create!(name: "Coaching 5 séances", billing_period: :custom, validity_days: 42,
                                                   unlimited_bookings: false, session_count: 5, booking_limit: 5, color: "#0f766e")
      plans[:pt5].contract_type_activities.create!(activity: coaching, price: 375)
      plans[:reformer8] = company.contract_types.create!(name: "Reformer 8 séances / mois", billing_period: :monthly,
                                                         unlimited_bookings: false, session_count: 8, booking_limit: 8, color: "#be185d")
      plans[:reformer8].contract_type_activities.create!(activity: reformer, price: 280)
      plans[:yoga] = company.contract_types.create!(name: "Yoga illimité", billing_period: :monthly, unlimited_bookings: true, color: "#0369a1")
      plans[:yoga].contract_type_activities.create!(activity: yoga, price: 160)

      # ---- the team ----------------------------------------------------------
      coach = lambda do |first, last, email|
        c = company.coaches.create!(first_name: first, last_name: last, email: email, phone: "+216 2#{rand(1_000_000..9_999_999)}")
        c.set_login!(email: email, password: password)
        c
      end
      amine = coach.call("Amine", "Ben Salah", "amine@studiolumen.tn")
      sarah = coach.call("Sarah", "Trabelsi", "sarah@studiolumen.tn")
      lina = coach.call("Lina", "Gharbi", "lina@studiolumen.tn")
      yassine = coach.call("Yassine", "Jaziri", "yassine@studiolumen.tn")

      # ---- the members -------------------------------------------------------
      people = [
        [ "Salma", "Bouazizi", :ems10, "Lombalgie chronique — intensité modérée sur le bas du dos." ],
        [ "Karim", "Mejri", :ems10, nil ],
        [ "Nour", "Hamdi", :reformer8, "Enceinte (5e mois) — pas d'EMS, Reformer adapté uniquement." ],
        [ "Ines", "Khelifi", :reformer8, nil ],
        [ "Youssef", "Ayari", :pt5, "Opéré du genou droit (ligaments croisés) en juin 2026." ],
        [ "Rania", "Chaabane", :yoga, nil ],
        [ "Mehdi", "Saidi", :ems10, nil ],
        [ "Amira", "Jebali", :yoga, nil ],
        [ "Hela", "Mansouri", :reformer8, "Hernie discale L4-L5 — éviter les flexions chargées." ],
        [ "Omar", "Dridi", :ems10, nil ],
        [ "Sonia", "Ferchichi", :yoga, nil ],
        [ "Walid", "Kammoun", :pt5, nil ],
        [ "Leila", "Ben Romdhane", :reformer8, nil ],
        [ "Aziz", "Trabelsi", :ems10, "Hypertension traitée — surveiller l'intensité." ],
        [ "Mariem", "Zouari", :yoga, nil ],
        [ "Fares", "Hammami", :ems10, nil ],
        [ "Dorra", "Sfar", :reformer8, nil ],
        [ "Bilel", "Gasmi", :yoga, nil ]
      ]
      activity_for = { ems10: ems, pt5: coaching, reformer8: reformer, yoga: yoga }

      members = people.each_with_index.map do |(first, last, plan_key, health), i|
        client = Client.create!(first_name: first, last_name: last, phone: "+216 #{[ 20, 22, 24, 25, 50, 52, 55, 98 ].sample} #{rand(100..999)} #{rand(100..999)}",
                                email: "#{first.downcase}.#{last.downcase.delete(' ')}@gmail.com")
        membership = client.join!(company)
        membership.update!(
          joined_at: (110 - i * 5).days.ago, health_notes: health,
          waiver_signed_on: (i % 6 == 5 ? nil : (110 - i * 5).days.ago.to_date),
          date_of_birth: Date.new(1980 + i, (i % 12) + 1, 10)
        )

        # Earlier terms first, so each member has a history and the revenue a
        # curve: one or two past purchases, then the one running now.
        plan = plans.fetch(plan_key)
        activity = activity_for.fetch(plan_key)
        starts = [ (100 - i * 4), 35, 0 ].first(i.even? ? 3 : 2).last(2)
        previous = nil
        starts.each_with_index do |days_ago, k|
          current = k == starts.size - 1
          start_on = (Date.current - (current ? (i % 7) * 3 + 2 : days_ago))
          paid = !current || i % 5 != 3
          contract = Contract.sell!(client: client, contract_type: plan, activity: activity, created_by: admin,
                                    starts_on: start_on, discount: (i % 6 == 0 ? 20 : 0),
                                    collect_payment: paid, payment_method: (i.odd? ? "cash" : "bank_transfer"))
          contract.payments.update_all(paid_at: start_on.in_time_zone(zone).change(hour: 10), created_at: start_on.in_time_zone(zone).change(hour: 10)) # rubocop:disable Rails/SkipsModelValidations
          # Each term renews the one before it, so the history reads as a chain.
          contract.update_columns(renewed_from_id: previous&.id) # rubocop:disable Rails/SkipsModelValidations
          contract.update_columns(status: :expired) unless current # rubocop:disable Rails/SkipsModelValidations
          previous = contract
        end
        client
      end

      # The member who shows the app: Salma has her own login.
      salma = members.first
      salma.update!(password: password, email_verified_at: Time.current)

      # Hela is on hold — a back injury — since last week.
      hela = members.find { |m| m.first_name == "Hela" }
      hela_contract = hela.current_contract(company)
      hela_contract.pause!
      hela_contract.update_columns(paused_at: 6.days.ago) # rubocop:disable Rails/SkipsModelValidations

      # ---- the week's schedule ------------------------------------------------
      monday = Date.current.beginning_of_week(:monday)
      weekly = lambda do |activity, coach_rec, space, days, time|
        company.recurring_schedules.create!(activity: activity, coach: coach_rec, space: space, weekdays: days,
                                            start_time: time, recurrence_type: :weekly,
                                            starts_on: monday - 21, ends_on: monday + 56).tap(&:generate_sessions!)
      end
      # Open EMS slots: two cabins, mornings and evenings — members take them from their app.
      %w[07:30 08:00 12:30 18:00 18:30 19:00].each { |t| weekly.call(ems, amine, cabin1, [ 1, 2, 3, 4, 5 ], t) }
      %w[09:00 17:30 19:30].each { |t| weekly.call(ems, yassine, cabin2, [ 1, 3, 5 ], t) }
      weekly.call(coaching, yassine, yoga_room, [ 2, 4 ], "10:00")
      weekly.call(coaching, yassine, yoga_room, [ 6 ], "09:00")
      %w[08:30 12:15 18:15].each { |t| weekly.call(reformer, sarah, reformer_room, [ 1, 3, 5 ], t) }
      %w[09:00 19:00].each { |t| weekly.call(reformer, sarah, reformer_room, [ 2, 4 ], t) }
      weekly.call(reformer, sarah, reformer_room, [ 6 ], "10:00")
      weekly.call(yoga, lina, yoga_room, [ 1, 3 ], "19:15")
      weekly.call(yoga, lina, yoga_room, [ 2, 4 ], "07:00")
      weekly.call(yoga, lina, yoga_room, [ 6 ], "11:00")

      # ---- bookings: three weeks of history and the week ahead ---------------
      current_of = members.index_with { |m| m.current_contract(company) }
      by_activity = members.group_by { |m| current_of[m]&.activity_id }
      now = Time.current
      # The past is filled newest first, so the days the demo shows are full
      # and only the oldest ones go short when a carnet runs low.
      past = company.sessions.where(starts_at: (now - 21.days)...now).includes(:activity).order(starts_at: :desc).to_a
      ahead = company.sessions.where(starts_at: now..(now + 7.days)).includes(:activity).order(:starts_at).to_a
      (past + ahead).each do |session|
        takers = by_activity.fetch(session.activity_id, []).reject { |m| m == hela }
        wanted = case session.activity.session_format
        when "individual" then rand < (session.starts_at < now ? 0.85 : 0.5) ? 1 : 0
        when "small_group" then rand(3..6)
        else rand(6..12)
        end
        takers.sample(wanted).each do |member|
          contract = current_of[member]
          if session.starts_at < now
            # Never before the carnet began, and always leave a few sessions on it.
            next if contract.starts_at && session.starts_at < contract.starts_at
            next if contract.remaining_bookings && contract.remaining_bookings <= 3
            next if session.bookings.where(client: member).exists?

            status = rand < 0.92 ? :completed : :no_show
            booking = session.bookings.create!(client: member, status: status, amount: 0, currency: "TND",
                                               payment_status: :paid, contract: contract, created_at: session.starts_at - 2.days)
            contract.decrement!(:remaining_bookings) if contract.remaining_bookings
            AttendanceRecord.mark!(booking: booking, status: status == :completed ? :present : :no_show, marked_by: session.coach&.staff_member&.user,
                                   checked_in_at: (status == :completed ? session.starts_at - 5.minutes : nil))
          else
            next if contract.remaining_bookings && contract.remaining_bookings <= 2
            begin
              session.book!(member)
            rescue ApplicationRecord::Refused
              next
            end
          end
        end
        session.update_columns(status: :completed) if session.ends_at < now # rubocop:disable Rails/SkipsModelValidations
      end
      # Reminders already went out for the bookings inside the next 24 hours.
      Booking.confirmed.joins(:session).where(sessions: { starts_at: now..(now + 24.hours) }).update_all(reminder_sent_at: now) # rubocop:disable Rails/SkipsModelValidations

      # A prospect booked on a trial tomorrow: Chiraz, who found the studio on Instagram.
      chiraz = Client.create!(first_name: "Chiraz", last_name: "Ben Youssef", phone: "+216 55 410 223", email: "chiraz.by@gmail.com")
      chiraz.join!(company).update!(joined_at: 1.day.ago, notes: "Vue sur Instagram — veut tester l'EMS avant le mariage de sa sœur (juin).")
      trial_slot = company.sessions.joins(:bookings).merge(Booking.confirmed).where(activity: ems).pluck(:id)
      slot = company.sessions.where(activity: ems, status: :scheduled).where(starts_at: (zone.now.tomorrow.beginning_of_day)..(zone.now.tomorrow.end_of_day))
                    .where.not(id: trial_slot).order(:starts_at).first
      slot&.book!(chiraz, trial: true)

      fixtures = {
        app: "http://localhost:4200",
        admin: { email: admin.email, password: password, name: admin.full_name },
        coach: { email: amine.email, password: password, name: amine.full_name },
        member: { email: salma.email, password: password, name: salma.full_name },
        prospect: chiraz.full_name
      }
      fixtures
    end

    # Writes the logins to tmp/demo.json and says what was built.
    def self.announce(fixtures)
      FileUtils.mkdir_p(Rails.root.join("tmp"))
      File.write(Rails.root.join("tmp/demo.json"), JSON.pretty_generate(fixtures))
      company = Company.joins(:admin).find_by!(users: { email: ADMIN_EMAIL })
      bookings = Booking.joins(:session).where(sessions: { company_id: company.id }).count
      puts "Studio Lumen ready — #{company.memberships.count} clients, #{company.sessions.count} sessions, " \
           "#{bookings} bookings. Logins in tmp/demo.json"
    end

    # Takes Studio Lumen back out of a database it shares with other data:
    # the admin account and, through it, the studio and everything in it
    # (User#companies cascades), the coaches' logins, and the members — but
    # only the ones who belong to no other gym, since a Client is a global
    # person. Nothing outside the studio is touched.
    def self.remove!
      admin = User.find_by(email: ADMIN_EMAIL)
      return if admin.nil?

      company_ids = admin.companies.ids
      member_ids = Membership.where(company_id: company_ids).pluck(:client_id)
      staff_user_ids = StaffMember.where(company_id: company_ids).pluck(:user_id) - [ admin.id ]

      # Company's own cascade destroys coaches and activities before the
      # schedules, sessions and contracts that point at them, which the
      # foreign keys refuse — so those go first.
      admin.companies.each do |company|
        company.recurring_schedules.destroy_all
        company.sessions.destroy_all
        company.payments.destroy_all
        company.contracts.destroy_all
      end
      admin.reload.destroy!
      Client.where(id: member_ids).where.missing(:memberships).destroy_all
      User.where(id: staff_user_ids).where.missing(:staff_members).where.missing(:companies).destroy_all
    end
  end
end
