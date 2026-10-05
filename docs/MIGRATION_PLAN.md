# Fitora — Migration Plan

> **Superseded (2026-09-24).** Everything below was carried out, rehearsed,
> and then squashed: there was no production data yet, so `db/migrate` now
> holds a single migration that creates the schema as it stands
> (`CreateFitoraSchema`). A new database is built from it or from
> `bin/rails db:schema:load`. `Migration::Audit` stays — it checks any
> restored database's invariants (`backup:restore_check`).

Governing constraint: **the application stays runnable after every phase.**
No phase ends with a broken build, a failing suite, or a half-migrated table.

## 1. Disposition of every existing table

| Table | Disposition | Note |
|---|---|---|
| `companies` | **MIGRATE** | + `settings` jsonb; − `locations_count`, `business_hours_*`, `working_days`, `primary_color` (backfilled into settings) |
| `users` | KEEP | |
| `staff_members` | **MIGRATE** | − `role` enum; `role_id` becomes NOT NULL |
| `roles` | KEEP | |
| `clients` | KEEP | global person — unchanged |
| `memberships` | KEEP | |
| `coaches` | KEEP | |
| `activities` | KEEP | |
| `spaces` | **NEW** | |
| `activity_spaces` | **NEW** | |
| `sessions` | **MIGRATE** | + `space_id`, + space exclusion constraint |
| `recurring_schedules` | KEEP | |
| `bookings` | **MIGRATE** | + `waitlist_position`, + `waitlisted` status, + check constraint |
| `attendance_records` | KEEP | |
| `contract_types` | KEEP | |
| `contract_type_activities` | KEEP | |
| `contracts` | **MIGRATE** | `activity_id` becomes nullable with new meaning |
| `contract_periods` | KEEP | |
| `payments` | KEEP | |
| `invoices` | KEEP | |
| `subscriptions` | KEEP | the gym's own SaaS subscription |
| `subscription_prices` | KEEP | |
| `platform_settings` | KEEP | one integer, but a superadmin edits it at runtime via the pricing endpoint — a constant would delete that feature |
| `audit_logs` | KEEP | |
| `notifications` | KEEP | |
| `support_tickets` | KEEP | |
| `app_updates` | KEEP | |
| `active_storage_*` | KEEP | |

Nothing holding member, booking, payment or subscription data is dropped.

## 2. Before any destructive step

1. `pg_dump` of production, restored and verified into a scratch database —
   a backup that has not been restored is not a backup.
2. The migration rehearsed end to end against that restored copy, with row
   counts compared before and after for every touched table.
3. Each destructive migration written with explicit `up` **and** `down`.
4. Backfill and removal in the same migration file, in that order, so a
   partially applied migration cannot leave data only in the dropped column.

## 3. Migration sequence

Each numbered item is one migration file, applied in order.

```
01  add companies.settings (jsonb, default {})           additive, safe
02  backfill settings from business_hours_*, working_days,
    primary_color; verify 100% coverage; then drop those columns
03  drop companies.locations_count
04  create spaces + activity_spaces
05  add sessions.space_id + no_overlapping_space_sessions
06  contracts.activity_id → nullable
07  bookings: waitlist_position + waitlisted status + check constraint
08  backfill staff_members.role_id from the role enum;
    assert zero NULLs; set NOT NULL; drop the role column
09  (withdrawn — platform_settings is kept, see DATABASE_DESIGN.md §3)
```

Migrations 01, 04, 05, 06, 07 are additive and reversible without data loss.
02, 03 and 08 are destructive and each carries a verified backfill plus a
hand-written `down`.

## 4. Phase plan

Each phase ends green: suite passing, app running, deployable.

| Phase | Scope | Done when |
|---|---|---|
| **1 — Analyse** ✅ | `CURRENT_ARCHITECTURE.md` | complete |
| **2 — Design** ✅ | this document set | complete |
| **3 — Backend core** | Migrations 01–09; `CompanySettings`; `Space`/`ActivitySpace` models + services + controllers + serializers; multi-activity `Contract#covers_activity?`; waitlist service; delete `ModuleCatalog` and the role enum | schema at target; new specs green; old specs green or deliberately rewritten |
| **4 — Authorization & tenancy** | `company_scope`/`find_in_company!`; sweep every controller for unscoped finds; add `spaces` + `settings` capabilities; Rack::Attack; the full `spec/requests/security/` matrix; strong-params audit | every denial test in `PERMISSIONS.md` §7 passes |
| **5 — Frontend architecture** | Restructure to §2 of `UI_ARCHITECTURE.md`; decompose `_fitora.scss`; delete `_adminlte.scss` and Bootstrap coupling; new primitives (`data-table`, `stat-tile`, `sheet`, …); five shells scaffolded | app runs on the new structure with existing screens ported, not yet redesigned |
| **6 — Role dashboards** | Admin, desk, coach, member, superadmin dashboards on the new primitives; `/coach/*` and `/me/*` additions | each role's dashboard answers its own question |
| **7 — UI redesign** | Every remaining screen rebuilt, shell by shell: superadmin → admin → desk → coach → member | no screen still on the old language; `_fitora.scss` under 250 lines |
| **8 — Onboarding & configuration** | Resumable onboarding (`API_DESIGN.md` §4); the company settings UI covering features, booking rules, hours, branding | a new company configures itself with no developer involvement |
| **9 — Data migration** | Rehearse on a restored dump; run against production; verify row counts and spot-check tenants | counts match; no orphans; a sample company reads correctly in every shell |
| **10 — Security & testing** | Full security audit against `PERMISSIONS.md` §7 + the brief's §23 list; UX walkthrough of every workflow in the brief's §34 | every listed attack denied; every listed workflow completes |

## 5. Rollback

Phases 3–8 are code; rollback is a deploy of the previous build, with the
caveat that migrations 02, 03 and 08 are one-way in practice once production
writes land on the new shape. Those three are therefore the **point of no
return** and are deployed in a single window, after the restored-dump
rehearsal, with the dump retained.

## 6. Risks

| Risk | Mitigation |
|---|---|
| A rewrite of the domain drops an invariant nobody remembers | The constraint inventory in `DATABASE_DESIGN.md` §5 is the checklist; a spec asserts each constraint exists |
| `settings` backfill misses a company | Migration 02 asserts 100% coverage and raises rather than proceeding |
| Unscoped `Model.find` survives the sweep | `spec/architecture/scoping_spec.rb` greps the sources and fails the build |
| Full UI redesign stalls between languages | Phase 7 proceeds shell by shell, each shipped complete; no shell is left half-converted |
| The rewrite loses behaviour the old specs encoded | Old specs are rewritten, never deleted, and the suite may not shrink |

## 7. Running it — the procedure

Two commands do the verifying. Both read; only `snapshot` writes, and only
to a file.

```bash
# 1. Take a backup and RESTORE it. A backup that has not been restored is
#    not a backup.
pg_dump -Fc $PRODUCTION_DB -f prod.dump
createdb fitora_rehearsal
pg_restore -d fitora_rehearsal prod.dump

# 2. Rehearse, against the restored copy — never against production first.
export DATABASE_URL=postgresql:///fitora_rehearsal
bin/rails migration:snapshot          # row counts on the OLD schema
bin/rails db:migrate
bin/rails migration:verify            # counts + invariants, exits non-zero on failure
bin/rails migration:spot_check        # every tenant read back through the app

# 3. Only if all three pass, repeat 2 against production, in one window,
#    keeping prod.dump.
unset DATABASE_URL
bin/rails migration:snapshot
bin/rails db:migrate
bin/rails migration:verify
bin/rails migration:spot_check
```

`migration:verify` checks, in `Migration::Audit`:

- **Row counts** against the snapshot, per table. Shrinkage fails; growth is
  fine, since a rehearsal on a live copy picks up writes.
- **Schema**: the dropped columns are gone, the new ones are there, and every
  constraint in `DATABASE_DESIGN.md` §5 exists.
- **Settings**: every company's opening hours landed, and no section the code
  does not declare is stored.
- **Roles**: no staff member left without one.
- **Orphans**: five references a migration nullified or rewrote.
- **Tenant leakage**: nine joins that cross a company boundary — a session on
  another gym's activity, a booking by a non-member, a plan priced for
  someone else's activity. No foreign key can catch these, and a migration
  that rewrote a reference is exactly where they would appear.

`migration:spot_check` reads every company back through the app's own
serializers and services — the admin dashboard, the company payload, the
branding, the settings, the setup flow, the resolved permissions, the
schedule, the team, the members and the contracts. It is the acceptance
criterion in §4 ("a sample company reads correctly in every shell") made
executable, for every company rather than a sample.

`Migration::Audit` reads with plain SQL and never through the models: a model
can only describe the schema it was written for, and the point is to find out
whether the database agrees.
