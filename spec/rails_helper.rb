# This file is copied to spec/ when you run 'rails generate rspec:install'
require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
# Prevent database truncation if the environment is production
abort("The Rails environment is running in production mode!") if Rails.env.production?
# Uncomment the line below in case you have `--require rails_helper` in the `.rspec` file
# that will avoid rails generators crashing because migrations haven't been run yet
# return unless Rails.env.test?
require 'rspec/rails'
# Add additional requires below this line. Rails is not loaded until this point!

# Requires supporting ruby files with custom matchers and macros, etc, in
# spec/support/ and its subdirectories. Files matching `spec/**/*_spec.rb` are
# run as spec files by default. This means that files in spec/support that end
# in _spec.rb will both be required and run as specs, causing the specs to be
# run twice. It is recommended that you do not name files matching this glob to
# end with _spec.rb. You can configure this pattern with the --pattern
# option on the command line or in ~/.rspec, .rspec or `.rspec-local`.
#
# The following line is provided for convenience purposes. It has the downside
# of increasing the boot-up time by auto-requiring all files in the support
# directory. Alternatively, in the individual `*_spec.rb` files, manually
# require only the support files necessary.
#
Rails.root.glob('spec/support/**/*.rb').sort_by(&:to_s).each { |f| require f }

# The API contract, written from the request specs: `OPENAPI=1 bundle exec
# rspec spec/requests` rewrites doc/openapi.yaml. CI regenerates it and fails
# on a diff, so a serializer change cannot reach the Angular or mobile app
# without the contract showing it. Shapes only — no example values, which
# would be random ids and timestamps and change every run.
if ENV["OPENAPI"]
  require "rspec/openapi"
  RSpec::OpenAPI.path = "doc/openapi.yaml"
  RSpec::OpenAPI.title = "Fitora API"
  RSpec::OpenAPI.application_version = "v1"
  RSpec::OpenAPI.enable_example = false
  RSpec::OpenAPI.info = { description: "Generated from spec/requests — do not edit by hand." }

  # The hook sees the gem's working copy, keyed by symbols or strings
  # depending on where a node came from; `key` finds either.
  key = ->(hash, name) { hash.key?(name.to_sym) ? name.to_sym : name.to_s }

  # A map keyed by record ids (plan_counts: { "<uuid>" => 3 }) would list
  # that run's random ids as properties. Say what it is instead: a map.
  uuid = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  as_map = lambda do |node|
    case node
    when Hash
      props = node[key.call(node, :properties)]
      if props.is_a?(Hash) && props.any? && props.keys.all? { |k| k.to_s.match?(uuid) }
        node.delete(key.call(node, :properties))
        node.delete(key.call(node, :required))
        node[:additionalProperties] = props.values.first
      end
      node.each_value { |child| as_map.call(child) }
    when Array
      node.each { |child| as_map.call(child) }
    end
  end

  # A response's description would be whichever example's name ran first.
  # The status says what it is.
  describe_by_status = lambda do |spec|
    (spec[key.call(spec, :paths)] || {}).each_value do |operations|
      operations.each_value do |operation|
        next unless operation.is_a?(Hash)

        (operation[key.call(operation, :responses)] || {}).each do |code, response|
          response[key.call(response, :description)] = Rack::Utils::HTTP_STATUS_CODES.fetch(code.to_s.to_i, code.to_s)
        end
      end
    end
  end

  RSpec::OpenAPI.post_process_hook = lambda do |_path, _records, spec|
    as_map.call(spec)
    describe_by_status.call(spec)
  end
end

# N+1 detection. On in CI, where an N+1 fails the build; opt in locally with
# `BULLET=1 bundle exec rspec`. Only N+1 loads raise: "unused eager loading"
# and "counter cache" advice are noisy on specs that build one or two rows.
# Bullet sees association loads only — a `find_by` per row is invisible to
# it, which is what spec/requests/performance/ counts instead.
if ENV["BULLET"] == "1" || ENV["CI"].present?
  require "bullet"
  Bullet.enable = true
  Bullet.bullet_logger = true
  Bullet.raise = true
  Bullet.add_footer = false
  Bullet.unused_eager_loading_enable = false
  Bullet.counter_cache_enable = false

  RSpec.configure do |config|
    config.before(:each) { Bullet.start_request }
    config.after(:each) { Bullet.perform_out_of_channel_notifications if Bullet.notification?; Bullet.end_request }
  end
end

# Ensures that the test database schema matches the current schema file.
# If there are pending migrations it will invoke `db:test:prepare` to
# recreate the test database by loading the schema.
# If you are not using ActiveRecord, you can remove these lines.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end
RSpec.configure do |config|
  # Remove this line if you're not using ActiveRecord or ActiveRecord fixtures
  config.fixture_paths = [
    Rails.root.join('spec/fixtures')
  ]

  # If you're not using ActiveRecord, or you'd prefer not to run each of your
  # examples within a transaction, remove the following line or assign false
  # instead of true.
  config.use_transactional_fixtures = true

  # You can uncomment this line to turn off ActiveRecord support entirely.
  # config.use_active_record = false

  # RSpec Rails uses metadata to mix in different behaviours to your tests,
  # for example enabling you to call `get` and `post` in request specs. e.g.:
  #
  #     RSpec.describe UsersController, type: :request do
  #       # ...
  #     end
  #
  # The different available types are documented in the features, such as in
  # https://rspec.info/features/8-0/rspec-rails
  #
  # You can also infer these behaviours automatically by company, e.g.
  # /spec/models would pull in the same behaviour as `type: :model` but this
  # behaviour is considered legacy and will be removed in a future version.
  #
  # To enable this behaviour uncomment the line below.
  # config.infer_spec_type_from_file_location!

  config.include FactoryBot::Syntax::Methods
  config.include ActiveSupport::Testing::TimeHelpers

  # Filter lines from Rails gems in backtraces.
  config.filter_rails_from_backtrace!
  # arbitrary gems may also be filtered via:
  # config.filter_gems_from_backtrace("gem name")
end
