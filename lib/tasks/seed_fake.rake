# Bulk-inserts fake clients into an admin's company to load-test the lists.
#
#   bin/rails seed:fake_clients                      # 10 000 into owner@fitora.test's company
#   COUNT=50000 bin/rails seed:fake_clients
#   EMAIL=admin2@fitora.test bin/rails seed:fake_clients
#   bin/rails seed:fake_clients_clear                # remove them again
#
# Fake rows carry a "[seed]" note so they can be found and cleared later.
namespace :seed do
  FIRST_NAMES = %w[
    Ahmed Mohamed Ali Youssef Karim Sami Walid Bilel Hamza Aziz Nizar Mehdi Skander
    Ines Sarra Nadia Mouna Rania Emna Yasmine Amira Salma Hiba Farah Chaima Dorra
    Amine Fares Oussama Ghassen Anis Wassim Marwen Zied Firas Slim Adam Rayan
    Leila Sonia Hela Rim Asma Maha Nour Malek Meriem Wafa Syrine Cyrine
  ].freeze

  LAST_NAMES = %w[
    Ben\ Ali Trabelsi Bouazizi Gharbi Jebali Chaabane Mansour Khelifi Ayari Hammami
    Nasri Sassi Ouhibi Mejri Brahmi Guesmi Abidi Ferchichi Dridi Zouari Bouzid
    Haddad Toumi Rekik Khemiri Baccouche Slama Ghanmi Jelassi Amri Belhadj Karray
    Ben\ Salah Ben\ Youssef Ben\ Amor Ben\ Romdhane Kefi Souissi Mkacher Tlili
  ].freeze

  GENDERS = %w[male female].freeze

  task fake_clients: :environment do
    count = Integer(ENV.fetch("COUNT", 10_000))
    email = ENV.fetch("EMAIL", "owner@fitora.test")

    admin = User.find_by!(email: email)
    company = admin.active_company or abort("#{email} has no active company")

    puts "Seeding #{count} fake clients into #{company.name} (#{email})…"
    now = Time.current
    base_phone = 20_000_000 + rand(9_000_000)

    started = Time.current
    inserted = 0
    count.times.each_slice(2_000).with_index do |slice, batch_i|
      people = slice.map do |i|
        first = FIRST_NAMES.sample
        last = LAST_NAMES.sample
        n = batch_i * 2_000 + i
        has_email = rand < 0.7
        joined = now - rand(0..900).days
        {
          person: {
            first_name: first,
            last_name: last,
            email: has_email ? "#{first.downcase}.#{last.downcase.tr(' ', '')}.#{n}@seed.fake" : nil,
            phone: "+216 #{base_phone + n}",
            active: true,
            created_at: joined,
            updated_at: joined
          },
          # What the gym writes about them lives on its membership.
          membership: {
            company_id: company.id,
            gender: GENDERS.sample,
            date_of_birth: Date.new(rand(1965..2007), rand(1..12), rand(1..28)),
            notes: "[seed]",
            active: rand < 0.9,
            joined_at: joined,
            created_at: joined,
            updated_at: joined
          }
        }
      end
      ids = Client.insert_all(people.map { |p| p[:person] }, returning: :id).rows.flatten
      rows = people.zip(ids).map { |p, id| p[:membership].merge(client_id: id) }
      Membership.insert_all(rows)
      inserted += rows.size
      print "\r  #{inserted}/#{count}"
    end

    elapsed = (Time.current - started).round(1)
    puts "\nDone in #{elapsed}s. #{company.name} now has #{company.clients.count} clients."
  end

  task fake_clients_clear: :environment do
    email = ENV.fetch("EMAIL", "owner@fitora.test")
    company = User.find_by!(email: email).active_company
    seeded = company.memberships.where("notes LIKE '[seed]%'")
    deleted = Client.where(id: seeded.select(:client_id)).destroy_all.size
    puts "Removed #{deleted} seeded clients from #{company.name}."
  end
end
