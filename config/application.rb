require_relative "boot"

require "csv"
require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Backend
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    # `rubocop/` holds custom cops loaded by .rubocop.yml's `require:` — it is
    # dev tooling, not application code, and must not be autoloaded/eager-loaded
    # (its `RuboCop::` namespace also trips Zeitwerk's inflector).
    config.autoload_lib(ignore: %w[assets tasks rubocop])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"

    # Where the Angular app is served. One default, read by the production
    # host list and by every link a mail sends (AccountMailer), so the two
    # can never point at different domains.
    config.x.app_host = ENV.fetch("APP_HOST", "app.fitora.com")
    config.x.frontend_url = ENV.fetch("FRONTEND_URL") do
      Rails.env.production? ? "https://#{config.x.app_host}" : "http://localhost:4200"
    end
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # Background jobs run on Sidekiq (see config/initializers/sidekiq.rb and
    # config/sidekiq_cron.yml). The default :async adapter is not persistent.
    config.active_job.queue_adapter = :sidekiq

    # Every table in this app uses a uuid primary key — Active Storage's own
    # tables (and their record_id/blob_id foreign keys) need to match, or
    # attaching a file to any model here fails.
    config.generators.orm :active_record, primary_key_type: :uuid
  end
end
