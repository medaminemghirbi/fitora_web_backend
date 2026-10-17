source "https://rubygems.org"

ruby file: ".ruby-version"

gem "rails", "~> 8.1.3"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"

# Removed from Ruby's default gems in 3.4 — used by config/application.rb and
# the payroll xlsx/report exports.
gem "csv"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"

# Password hashing for User#password
gem "bcrypt", "~> 3.1.7"

# JWT encode/decode for API authentication
gem "jwt"

# Cross-Origin Resource Sharing, needed for the Angular dev server
gem "rack-cors"

# Rate-limits POST /api/v1/auth/login (see config/initializers/rack_attack.rb)
# — the real login endpoint had zero brute-force protection.
gem "rack-attack"

# Error tracking (config/initializers/sentry.rb) — safely a no-op with no
# SENTRY_DSN set. sentry-sidekiq covers background jobs, which otherwise
# fail completely silently (no request, no user watching, nothing).
gem "sentry-ruby"
gem "sentry-rails"
gem "sentry-sidekiq"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy as a Docker container to any host (see config/deploy.yml).
gem "kamal", require: false

# S3-compatible object storage for Active Storage in production
# (config/storage.yml :production).
gem "aws-sdk-s3", require: false

# Styled .xlsx generation (colored cells) for the admin's Premium report export
gem "caxlsx"

# PDF invoice/receipt generation for the Premium membership receipt download
gem "prawn"
gem "prawn-table"
# Prawn uses Matrix internally — no longer a Ruby default gem, must be explicit
gem "matrix"

# QR code for the company mobile pairing key — generated server-side (SVG)
# so the key itself never leaves the app to a third-party QR API.
gem "rqrcode"

# Background jobs (expiry scans, notification fan-out) + the ActionCable
# Redis pub/sub backend for real-time notifications. Redis already runs
# locally; set REDIS_URL to point elsewhere.
gem "redis", "~> 6"
gem "sidekiq", "~> 7"
gem "sidekiq-cron", "~> 2"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  gem "rspec-rails"
  gem "factory_bot_rails"

  # N+1 / unused-eager-loading detection — driven by spec/rails_helper.rb
  # under BULLET=1, so it stays out of the way of a normal test run.
  gem "bullet", require: false
  gem "dotenv-rails"

  # Known-vulnerable gem versions, checked in CI against the ruby-advisory-db.
  gem "bundler-audit", require: false
end

group :test do
  # Coverage, with a floor CI enforces (spec/spec_helper.rb).
  gem "simplecov", require: false

  # Writes doc/openapi.yaml from the request specs (OPENAPI=1). CI
  # regenerates it and fails if the API changed without the file changing.
  gem "rspec-openapi", require: false
end
