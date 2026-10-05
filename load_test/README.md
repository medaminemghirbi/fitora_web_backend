# Load testing

k6 scripts that drive real HTTP traffic against a running Fitora backend —
the member booking flow (login → browse classes → book) and the staff/owner
flow (login → dashboard → client list) — weighted like real traffic
(members vastly outnumber staff).

## Setup

1. Start the app against a real Postgres + Redis (dev is fine). Every k6 VU
   shares one real source IP (your machine), which the login rate limiter
   can't tell apart from an attacker sending that many requests/second from
   one place — set `DISABLE_RACK_ATTACK=1` for a local run so the test
   measures the app, not the rate limiter (never set this outside a local
   load test — see config/initializers/rack_attack.rb):
   ```bash
   DISABLE_RACK_ATTACK=1 bin/rails server
   bundle exec sidekiq   # not required for the scripted flows, but notifications/jobs won't run without it
   ```
2. Seed a realistic dataset — companies, staff, coaches, upcoming bookable
   sessions, and real loginable clients with an active contract each:
   ```bash
   bin/rails load_test:seed
   # or, bigger:
   COMPANIES=20 CLIENTS_PER_COMPANY=1000 SESSIONS_PER_COMPANY=60 bin/rails load_test:seed
   ```
   This writes `load_test/data/accounts.json` (gitignored — regenerate
   per environment, don't hand-edit it). `bin/rails load_test:clear` removes
   everything it created.
3. Install k6 if you don't have it: https://k6.io/docs/get-started/installation/

## Running

```bash
k6 run load_test/k6/scenario.js
```

Defaults to a staged ramp up to 300 concurrent "members" and 20 concurrent
"staff" against `http://localhost:3000` (from `accounts.json`). Push it
further, or point it elsewhere:

```bash
k6 run -e MAX_MEMBER_VUS=2000 -e MAX_STAFF_VUS=100 load_test/k6/scenario.js
k6 run -e BASE_URL=https://staging.fitora.io load_test/k6/scenario.js
```

k6 prints p95/p99 latency and error rate per endpoint at the end, and the
thresholds in `scenario.js` fail the run if error rate exceeds 1% or
latency exceeds the per-endpoint targets — that failure point *is* the
finding. A `booking_conflicts` counter tracks expected 422/409s (a class
filling up between browse and book) separately from real errors.

## What this actually tells you

Run against a single local `bin/rails server`, this finds where **this
box's current config** breaks — useful for catching regressions and for a
before/after comparison of an optimization (see the schema/index changes
in `db/migrate/`). It is not a measurement of "can we handle 10,000
concurrent users" — that requires the topology below, and only a test
against *that* topology (staging, sized like production) answers it.

## Getting from here to real 10K-concurrent capacity

The current `config/deploy.yml` is one VPS, `WEB_CONCURRENCY: 2` x
`RAILS_MAX_THREADS: 5` = 10 concurrent request-handling threads total, one
Postgres and one Redis colocated on the same box. That comfortably serves
normal gym-app traffic; it is not sized for 10,000 truly simultaneous
requests, and no amount of Puma tuning alone gets it there — 10,000 live
connections each holding a Postgres connection would need 10,000 Postgres
connections, far past any single Postgres instance's practical limit
(`max_connections` defaults to 100, and even a tuned large instance tops
out in the low thousands before performance falls off a cliff).

What actually closes that gap, in order of what to do first:

1. **PgBouncer in front of Postgres**, in `transaction` pooling mode. This
   is the load-bearing piece — it lets thousands of app-side connections
   share a small pool of real Postgres connections (dozens, not
   thousands). Add it as a Kamal accessory between the app and `fitora-db`,
   point `DATABASE_URL` at it instead of Postgres directly. Transaction
   pooling means `config/database.yml` needs
   `prepared_statements: false` and `advisory_locks: false` added to the
   `production:` block — PgBouncer in transaction mode can't guarantee a
   later query in the same "connection" lands on the same real Postgres
   backend, which breaks both features.
2. **Horizontal Puma replicas.** Add more entries under `servers.web` in
   `deploy.yml` — Kamal's built-in proxy already load-balances across
   whatever hosts are listed there. Each replica still needs
   `RAILS_MAX_THREADS` x its own DB pool sized sanely (see the
   `servers.worker` env override already in `deploy.yml` for the pattern —
   apply the same idea per web replica if they ever need different
   sizing).
3. **Move Postgres and Redis off the app boxes** onto their own
   host(s) once you're running multiple web replicas — colocating them on
   one VPS (today's setup) stops making sense past a couple of replicas.
4. **Re-run this k6 script against that topology** (staging, sized like
   the real target) with `-e BASE_URL=... -e MAX_MEMBER_VUS=10000` to get
   an actual answer, rather than trusting the math above blind.

None of this is wired into `deploy.yml` today — it still has placeholder
`<VPS_IP>` values and describes a single-box deployment. Treat the above as
the plan for when real capacity is being provisioned, not a config to copy
in blind.
