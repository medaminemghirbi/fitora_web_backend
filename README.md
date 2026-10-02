# Gymly Backend

Rails 8 API backend for Gymly — a multi-tenant gym/studio management platform
(clients, bookings, sessions, contracts, staff, payroll, attendance, and
real-time notifications).

## Stack

- **Ruby** 3.4.7 (see [.ruby-version](.ruby-version))
- **Rails** 8.1 (`config.api_only = true`)
- **PostgreSQL** — primary datastore, UUID primary keys everywhere
- **Redis** — Sidekiq queue backend + ActionCable pub/sub
- **Sidekiq** (+ `sidekiq-cron`) — background jobs (expiry scans, notification fan-out)
- **ActionCable** — real-time notifications
- **JWT** (`jwt` gem) — API authentication
- **Kamal** — Docker-based deployment
- **Sentry** — error tracking (`sentry-ruby`, `sentry-rails`, `sentry-sidekiq`)

## Requirements

- Ruby 3.4.7 (use [rbenv](https://github.com/rbenv/rbenv)/[asdf](https://asdf-vm.com/) with the provided `.ruby-version`)
- PostgreSQL 14+
- Redis 6+

## Setup

```bash
# Install dependencies
bin/setup --skip-server   # or: bundle install

# Configure environment
cp .env.example .env      # then fill in local values as needed

# Create and migrate the database
bin/rails db:create db:schema:load
```

## Running the app

```bash
bin/rails server           # API on http://localhost:3000
bundle exec sidekiq -c 5   # background job worker (needed for notifications/scans)
```

Or run both with [foreman](https://github.com/ddollar/foreman) via `Procfile.dev`:

```bash
foreman start -f Procfile.dev
```

The Sidekiq dashboard is mounted at `/sidekiq` — open in development, or in
other environments once `SIDEKIQ_WEB_PASSWORD` is set (HTTP basic auth).

## Configuration

All runtime configuration is via environment variables — see
[.env.example](.env.example) for the full list and inline documentation
(datastores, CORS origins, SMS provider, Sentry, etc). Locally these are
loaded from `.env` by `dotenv-rails`; in production they're set on the host /
in the Kamal deploy config.

## Testing

The test suite uses RSpec, FactoryBot, and a real PostgreSQL test database.

```bash
bin/rails db:test:prepare   # first run / after schema changes
bundle exec rspec           # full suite
bundle exec rspec spec/models/client_spec.rb   # single file
```

Under CI (`CI=true`) the same run also fails on any N+1 query (Bullet) and on
line/branch coverage below the floor in `spec/spec_helper.rb` (SimpleCov,
report in `coverage/`). `COVERAGE=0` skips coverage for a quick local run.

### API contract

`doc/openapi.yaml` is written from the request specs, and CI fails if it no
longer matches the API. After changing what an endpoint accepts or returns:

```bash
rm doc/openapi.yaml && OPENAPI=1 COVERAGE=0 bundle exec rspec spec/requests --order defined
```

and commit the result.

### End-to-end smoke suite

The Playwright journeys live in the frontend repo (`npm run e2e` there). They
boot this API on port 3100 against its own database, `backend_e2e`, which
`bin/rails e2e:seed` resets — it refuses to run on any database not named
`*_e2e`.

## Linting & static analysis

```bash
bundle exec rubocop                 # style (Omakase Rails style + house cops in lib/rubocop/cop/gymly)
bundle exec brakeman --no-pager     # security static analysis
bundle exec bundle-audit check --update   # gems with a published advisory
```

## Continuous Integration

Every push and pull request runs lint, security scan, and the full test suite —
see [.github/workflows/ci.yml](.github/workflows/ci.yml).

## Deployment

Deployed as a Docker container via [Kamal](https://kamal-deploy.org/) — see
[config/deploy.yml](config/deploy.yml) and the [Dockerfile](Dockerfile).

```bash
bin/kamal deploy
```

Production refuses to boot without `SMTP_*` and `APP_HOST`
(`config/initializers/required_env.rb`) — without mail, no admin can confirm
their address and nothing opens. Every secret the deploy needs is listed in
`.kamal/secrets.example`.

## Backups

The `backup` accessory in `config/deploy.yml` dumps the database nightly,
encrypts it with `PASSPHRASE`, and ships it to an S3-compatible bucket, kept
14 days. Restore one now and then — a backup nobody has restored is not a
backup:

```bash
bin/rails backup:restore_check FILE=path/to/backup.dump        # or .dump.gpg with PASSPHRASE set
```

It restores into a scratch database next to the real one, runs the
`Migration::Audit` invariants on it (orphans, cross-tenant references,
constraints), and drops it again.

## Project structure

- `app/controllers/api/v1` — versioned JSON API, namespaced by role where relevant (`superadmin/`, `admin/`, `me/`)
- `app/models` — the data and the business rules on it: booking, cancelling, selling a plan, taking a payment are model methods (`Session#book!`, `Booking#cancel!`, `Contract.sell!`, `Payment.collect!`, …). A rule a request breaks raises `ApplicationRecord::Refused`, which the API answers with a 422
- `app/lib` — code that isn't a business rule: PDF receipts and schedules, spreadsheet reports, dashboard figures, CSV import/export, JWT, the SMS gateway client
- `app/models/concerns` — shared model behavior (email verification, password reset, photo attachment)
- `app/jobs` — Sidekiq background jobs, mostly scheduled scans (see `config/sidekiq_cron.yml`)
- `app/policies` — authorization
- `app/serializers` — JSON response shaping
- `lib/rubocop/cop/gymly` — house Rubocop cops (e.g. tenant-scoping enforcement)
