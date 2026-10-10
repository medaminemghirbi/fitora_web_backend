# Brute-force protection for the real login endpoint — POST
# /api/v1/auth/login had no rate limiting at all until now: an attacker
# could try passwords as fast as the network allowed, for any account
# (admin/staff/client all share this one endpoint). Also lightly covers
# password-reset requests and admin self-registration, the other
# unauthenticated account surfaces, to stop them being scripted for
# inbox-spam or mass account creation.
#
# Disabled in test by default — spec/requests/rack_attack_spec.rb flips it
# on for the duration of its own examples only. Also disabled when running
# a local k6 load test (load_test/): every VU there shares one real source
# IP, which is nothing like the thousands of distinct IPs real concurrent
# traffic arrives from, so the per-IP throttle would just measure itself
# instead of the app. Never set DISABLE_RACK_ATTACK outside that.
Rack::Attack.enabled = !Rails.env.test? && ENV["DISABLE_RACK_ATTACK"] != "1"

# Shared across Puma workers (WEB_CONCURRENCY in config/deploy.yml) — an
# in-memory store would count separately per worker, making the limits
# below several times more permissive than they look. Redis is already a
# hard dependency (Sidekiq/ActionCable).
Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(
  url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1")
)

# Short, tight window — stops a fast automated guessing burst outright.
# Sized well above what real concurrent traffic from one IP looks like
# (a gym's own front-desk wifi, an office, mobile carrier NAT/CGNAT can
# put a lot of genuine simultaneous logins behind one address — a load
# test surfaced this throttling out nearly all of them at 5/20s) — the
# per-email throttle below is the real brute-force defense; this one is
# a backstop against a single-IP flood, not the primary defense.
Rack::Attack.throttle("logins/ip/burst", limit: 60, period: 20.seconds) do |req|
  req.ip if req.post? && req.path == "/api/v1/auth/login"
end

# Longer window, higher ceiling — catches a slower attempt that stays
# under the burst limit but is still clearly not a human typing a password.
Rack::Attack.throttle("logins/ip/sustained", limit: 300, period: 5.minutes) do |req|
  req.ip if req.post? && req.path == "/api/v1/auth/login"
end

# Keyed on the attempted email rather than the caller's IP — the burst/
# sustained throttles above are per-IP, so a distributed attempt (many
# IPs, one targeted account) would sail through both. Cheaply defeated by
# also throttling per email tried, regardless of source. This is the throttle
# that actually stops password guessing — it stays tight regardless of the
# per-IP limits above, since it doesn't matter how many legitimate logins
# share an IP if only one of them is for the account being guessed.
#
# Three windows on the same key. The 20-second one alone still allowed about
# 21,600 guesses a day against one account; the hourly and daily ceilings
# bring that to 50, while someone who mistypes a few times in a row is only
# ever held back by the short one.
login_email = lambda do |req|
  next unless req.post? && req.path == "/api/v1/auth/login"

  req.params["email"].to_s.downcase.strip.presence
end
Rack::Attack.throttle("logins/email", limit: 5, period: 20.seconds, &login_email)
Rack::Attack.throttle("logins/email/hour", limit: 20, period: 1.hour, &login_email)
Rack::Attack.throttle("logins/email/day", limit: 50, period: 1.day, &login_email)

# Every endpoint that takes a password to prove who you are, other than
# login: changing it, and deleting a member account. Signed in already, but a
# stolen token should not be a way to guess the password behind it.
PASSWORD_CHECKS = [
  [ "PATCH", "/api/v1/auth/password" ],
  [ "DELETE", "/api/v1/me/account" ]
].freeze
Rack::Attack.throttle("password_checks/ip", limit: 10, period: 5.minutes) do |req|
  req.ip if PASSWORD_CHECKS.include?([ req.request_method, req.path ])
end

# The emailed-token endpoints: accepting an invitation, finishing a reset,
# confirming an address. The tokens are 256 bits and not guessable, but
# nothing unauthenticated should take unlimited attempts.
Rack::Attack.throttle("emailed_tokens/ip", limit: 10, period: 1.minute) do |req|
  req.ip if req.patch? && req.path.match?(%r{\A/api/v1/(invitations|password_resets|email_verifications)/[^/]+\z})
end

Rack::Attack.throttle("password_resets/ip", limit: 5, period: 1.minute) do |req|
  req.ip if req.post? && req.path == "/api/v1/password_resets"
end

# Signing up is unauthenticated, creates a User and emails the address given,
# with no ownership check. Unthrottled, a script could mass-create accounts or
# use Fitora's own mailer to bomb a third party's inbox.
Rack::Attack.throttle("register/ip", limit: 5, period: 10.minutes) do |req|
  req.ip if req.post? && req.path == "/api/v1/auth/register"
end

# Re-sending a verification email is unauthenticated and mails whatever
# address it is given — the same inbox-bombing surface as a password reset,
# and it was the one account-mail endpoint with no ceiling on it.
Rack::Attack.throttle("email_verifications/ip", limit: 5, period: 1.minute) do |req|
  req.ip if req.post? && req.path == "/api/v1/email_verifications"
end

Rack::Attack.throttled_responder = lambda do |_request|
  [ 429, { "Content-Type" => "application/json" }, [ { error: "rate_limited" }.to_json ] ]
end

# The mobile app's key lookup is public: a coach key lists a salle's team.
# Keys are long and random, but nothing unauthenticated takes unlimited
# guesses.
Rack::Attack.throttle("app_config/ip", limit: 20, period: 1.minute) do |req|
  req.ip if req.get? && req.path.match?(%r{\A/api/v1/tenants/[^/]+/app_config\z})
end
