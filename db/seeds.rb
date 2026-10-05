# Fitora seed data — minimal bootstrap only.
#
# Platform superadmin: admin@fitora.test / password123
#
# No demo gym, admin, staff, or clients — this used to seed a full "Fitora
# Fitness Sousse" dataset (coaches, activities, sessions, contracts,
# bookings, payments, documents…) for manual testing. That's gone: seeds.rb
# now only creates what any fresh install actually needs — the reference
# subscription price and the one account that can reach /superadmin. To try the
# admin side, register a real company via POST /api/v1/company (or
# /auth/register on the frontend) after seeding.

puts "Seeding the reference subscription prices + platform settings..."
# One row per company-limit tier (1 / 3 / unlimited) — every other
# currency's first-seen price for a tier is derived from this one (see
# SubscriptionPrice.for), so all three need to exist up front.
SubscriptionPrice::PLANS.each { |plan| SubscriptionPrice.for(SubscriptionPrice::REFERENCE_CURRENCY, plan: plan) }
PlatformSetting.current # the singleton (annual discount = 10%)

puts "Seeding the activity catalogue..."
load Rails.root.join("db/seeds/activity_templates.rb")

puts "Seeding the platform superadmin account..."
User.find_or_create_by!(email: "admin@fitora.test") do |u|
  u.first_name = "Fitora"
  u.last_name = "Superadmin"
  u.password = "password123"
  u.role = :superadmin
  u.locale = "fr"
end

puts "Seed complete."
puts "Platform superadmin: admin@fitora.test / password123"
