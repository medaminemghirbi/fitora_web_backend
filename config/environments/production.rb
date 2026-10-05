require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Serve the baked-in Angular SPA (the Dockerfile copies it into public/) and
  # cache its digest-stamped assets for far-future expiry.
  config.public_file_server.enabled = true
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Origins allowed to open the /cable WebSocket. Set FRONTEND_ORIGINS to the
  # deployed front-end URL(s), comma-separated.
  config.action_cable.allowed_request_origins =
    ENV.fetch("FRONTEND_ORIGINS", "https://app.fitora.io").split(",")

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Outgoing mail. Configured entirely from ENV so no SMTP secret lives in the
  # repo; if SMTP_ADDRESS is unset, delivery is a no-op (dev/staging safety).
  app_host = config.x.app_host
  config.action_mailer.default_url_options = { host: app_host, protocol: "https" }
  config.action_mailer.raise_delivery_errors = ENV["SMTP_ADDRESS"].present?
  config.action_mailer.perform_deliveries = ENV["SMTP_ADDRESS"].present?
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = {
    address:              ENV["SMTP_ADDRESS"],
    port:                 ENV.fetch("SMTP_PORT", 587).to_i,
    user_name:            ENV["SMTP_USERNAME"],
    password:             ENV["SMTP_PASSWORD"],
    authentication:       ENV.fetch("SMTP_AUTHENTICATION", "plain"),
    enable_starttls_auto: true
  }

  # Object storage: S3-compatible bucket when S3_BUCKET is set (see
  # config/storage.yml), else local disk on a persistent volume.
  config.active_storage.service = ENV["S3_BUCKET"].present? ? :amazon : :local

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # DNS-rebinding / Host-header protection. Allow the app host plus anything
  # listed in ALLOWED_HOSTS (comma-separated). The load-balancer health check
  # hits the container by IP, so exempt /up.
  config.hosts << app_host
  config.hosts << /.*\.#{Regexp.escape(app_host.split('.').last(2).join('.'))}\z/
  ENV.fetch("ALLOWED_HOSTS", "").split(",").each { |h| config.hosts << h.strip }
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
