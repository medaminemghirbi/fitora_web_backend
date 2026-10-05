# What production cannot run correctly without, checked at boot.
#
# Each of these used to fail silently. With no SMTP_ADDRESS the mailer turned
# its own deliveries off, and since an admin must confirm their email before
# anything opens, every gym that signed up would have waited for a link that
# was never sent. With APP_HOST unset, every emailed link pointed at the
# default domain rather than this one. A server that refuses to start says so
# at deploy time instead.
#
# SKIP_REQUIRED_ENV_CHECK=1 runs a one-off task (a console, a migration) on a
# box that is not meant to serve traffic.
module RequiredEnv
  REQUIRED = {
    "SMTP_ADDRESS" => "outgoing mail — account confirmation, password resets and member invitations",
    "SMTP_USERNAME" => "outgoing mail",
    "SMTP_PASSWORD" => "outgoing mail",
    "APP_HOST" => "the domain every emailed link points at"
  }.freeze

  # Worth a warning, not a refusal: the app works without them, just blind.
  RECOMMENDED = {
    "SENTRY_DSN" => "error reporting",
    "SIDEKIQ_WEB_PASSWORD" => "the /sidekiq dashboard",
    # PayoutAccount falls back to generic "settle with Fitora" wording.
    "FITORA_RIB" => "Fitora's bank details on the subscription page"
  }.freeze

  def self.missing(env = ENV, keys = REQUIRED)
    keys.reject { |key, _| env[key].present? }
  end

  def self.check!(env = ENV)
    missing(env, RECOMMENDED).each do |key, purpose|
      Rails.logger.warn("[required_env] #{key} is not set — #{purpose} is off.")
    end

    absent = missing(env)
    return if absent.empty?

    raise "Missing production configuration:\n" +
          absent.map { |key, purpose| "  #{key} (#{purpose})" }.join("\n") +
          "\nSet them in config/deploy.yml / .kamal/secrets, or SKIP_REQUIRED_ENV_CHECK=1 for a one-off task."
  end
end

RequiredEnv.check! if Rails.env.production? && ENV["SKIP_REQUIRED_ENV_CHECK"].blank?
