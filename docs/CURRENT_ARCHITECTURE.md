# Gymly — Current Architecture (Phase 1 analysis)

Snapshot date: 2026-09-19. Branch `FEATURE` (backend + frontend are two
separate git repositories under `/home/amine/Documents/gymly/`).

This document records what exists today, verified against the code and the
schema — not what the roadmap wants. Gaps against the target vision are
listed in §9 and nowhere else, so the description above them stays factual.

---

## 1. Stack

| Layer | Technology |
|---|---|
| Backend | Rails 8.1, API-only (`ActionController::API`), PostgreSQL (UUID PKs everywhere), Sidekiq + Sidekiq-cron, ActionCable, Active Storage |
| Frontend | Angular (standalone components, signals), SCSS token layer, Bootstrap-derived variables |
| Auth | Custom JWT (`JwtService`), no Devise |
| Extensions | `pgcrypto`, `pg_trgm` (search), `btree_gist` (exclusion constraints) |
| Serving | Rails serves the Angular build; `SpaController` catch-all handles deep links |

Backend: 33 models, 39 controllers, ~20 service namespaces, 24 serializers,
101 RSpec files. Frontend: 289 `.ts` files across `core/`, `shared/`,
`layout/`, `features/`.

---

## 2. Domain model as built

```
User (admin | staff | superadmin)
 ├─ owns → Company (a user may own several; User#company_limit)
 └─ StaffMember → Company, Role, optional Coach

Company (the tenant AND the venue — there is no Location/Space table)
 ├─ Activity        (name, session_format, capacity, duration)
 ├─ Coach
 ├─ Role            (company-scoped, editable permission sets)
 ├─ Session         (activity + coach + starts_at/ends_at + capacity + price)
 │    └─ RecurringSchedule  (weekdays, start_time, date range → generates Sessions)
 ├─ ContractType    (= subscription plan: billing_period, session_count,
 │    │               booking_limit, unlimited_bookings, priority_booking)
 │    └─ ContractTypeActivity (join, carries per-activity price)
 ├─ Contract        (= a member's subscription: client + contract_type + activity)
 │    └─ ContractPeriod (starts_at/expires_at, status, remaining_bookings,
 │                       base_price/discount/final_price, payment_status)
 ├─ Membership      (Client ↔ Company join)
 ├─ Payment, Invoice, AuditLog, Notification, SupportTicket
 └─ Subscription    (the gym's own SaaS subscription to Gymly)

Client (GLOBAL person, not company-scoped — own login, own password digest)
 ├─ Membership → Company (many)
 ├─ Contract → Company
 └─ Booking → Session, optional ContractPeriod
      └─ AttendanceRecord (checked_in_at / checked_out_at / status)
```

Key modelling facts:

- **`Client` is a global entity.** It has no `company_id`; the link to a gym
  is `memberships`. This was a deliberate B2B+C2B change — one person can
  belong to several gyms with one login.
- **`Company` is the venue.** `Location`/`Salle` were deleted on purpose;
  `companies.locations_count` is a leftover counter column.
- **Plan definition and member state are already separate**: `ContractType`
  (definition) vs `Contract` + `ContractPeriod` (state, session balance,
  payment status). `remaining_bookings` has a DB check constraint.
- **Capacity is per-activity and per-session.** `Activity#session_format`
  (`individual` 1 / `small_group` 2–9 / `collective` 10+) constrains
  `capacity` via a model validation; each `Session` snapshots its own
  `capacity`. EMS (1), Pilates (10), Boxing (20) are already expressible.
- **Double-booking a coach is prevented in the database**, not in Ruby:
  `sessions` carries a GiST exclusion constraint on
  `coach_id + tsrange(starts_at, ends_at)` for scheduled sessions.
- **A held booking is unique per (session, client)** via a partial unique index.

---

## 3. Authentication

`ApplicationController#authenticate_request!` decodes a bearer JWT and
resolves **exactly one** of two principals, never both:

- `claims[:user_id]` → `@current_user` (staff-side: admin, staff, superadmin)
- `claims[:client_id]` → `@current_client` (member-side)

`claims[:impersonator_id]` supports superadmin impersonation of an admin.
`users.token_version` allows global token invalidation. Sentry gets
user/company tags per request.

Account recovery and email verification use hashed, single-use tokens
(`*_token_digest` columns with unique indexes) — no plaintext tokens stored.

---

## 4. Tenancy and authorization

Tenancy is derived, never accepted from the client. `Api::V1::BaseController`:

```ruby
def current_company
  @current_company ||= current_user&.active_company || current_staff_member&.company
end
```

- An admin's tenant is `users.active_company_id`, switched through
  `POST /companies/:id/switch` — not a request parameter.
- A staff member's tenant is `staff_members.company_id`.
- For member logins, `?company_id=` is *checked* against the client's own
  memberships (`member_company`), and an unmatched value returns **404, not
  403**, so a gym a person has not joined is indistinguishable from one that
  does not exist.

Authorization is capability-based:

- `Permission::CATALOG` — 11 code-defined capabilities (`clients`,
  `activities`, `coaches`, `sessions`, `bookings`, `contracts`,
  `contract_types`, `payments`, `reports`, `revenue`, `checkin`).
- `Role` — company-scoped rows holding a subset of those, seeded with four
  built-ins (`admin`, `moderator`, `moderator`, `coach`), renameable and
  re-permissionable; custom roles allowed. `moderator` already omits
  catalogues and `revenue`; `coach` has only `checkin`.
- Controllers gate with `require_capability!`, `require_admin!`,
  `require_superadmin!`, `require_client!`, `require_staff!`.
- The admin always passes `capability?` unconditionally.

Platform superadmin (`users.role == superadmin`) is separated by namespace: everything
it can do lives under `Api::V1::Superadmin::*`. It has no `current_company`.

**Commercial gating** is separate from authorization: `enforce_trial_lock!`
returns 402 for a locked company, with a narrow allowlist so a locked admin
can still read their subscription, their invoices, and switch companies.

`ModuleCatalog` still exists but is now inert: every company has every
feature, and `permissions_for` ignores its argument. The `mod_*` boolean
columns described in older notes are **gone from the schema**.

---

## 5. API surface

Single version, `/api/v1`, REST-shaped, with four namespaces that map to the
four audiences:

- root (`/activities`, `/sessions`, `/bookings`, `/clients`, `/contracts`,
  `/contract_types`, `/payments`, `/staff`, `/roles`, `/attendance`,
  `/recurring_schedules`, `/audit_logs`, …) — staff-side
- `/me/*` — member portal (profile, sessions, bookings, cancel)
- `/admin/*` — dashboard, revenue, report export
- `/superadmin/*` — companies, impersonation, invoices, SaaS pricing, support,
  release notes

`GET /bootstrap` returns the whole post-login context in one call (user,
company, permissions, setup state). Responses go through 24 hand-written
serializers — no `to_json` on models in controllers.

---

## 6. Business logic placement

Logic lives in `app/services/<domain>/` (bookings, contracts, subscriptions,
sessions, recurring_schedules, check_ins, attendance, payments, invoices,
receipts, payroll, reports, dashboard, notifications, permissions, sms,
data_exchange, audit_logs). Controllers are thin. This is the right shape
already.

> **Since 2026-10-02** the service objects are gone: the rules are model
> methods and what remained (PDFs, reports, CSV, JWT, SMS) is in `app/lib`.
> See `TARGET_ARCHITECTURE.md` §4 and `PHASE_LOG.md`.

---

## 7. Frontend architecture

```
core/        auth, guards, interceptors, models (typed), services (1 per API resource), configuration
shared/      components/ (modal, toast, pagination, confirm, empty-state…)
             ui/         (page-header, kpi-card, drawer, form-modal, skeleton,
                          searchable-select, filter-rail, wizard-steps, checkin-panel…)
layout/      admin-shell, coach-shell, member-shell, superadmin-shell, navbar, mobile-bar
features/    landing, auth, b2b/auth, admin/*, coach/*, member/*, superadmin/*, account-locked
```

- Four shells, four experiences, routed by role: `/admin`, `/coach`,
  `/member`, `/superadmin`.
- Guards: `authGuard`, `guestGuard`, `roleGuard(role)`,
  `staffRoleGuard(key)`, `capabilityGuard(key)`, `companyGuard`,
  `noCompanyGuard`, `memberGuard`, `settingsAccessGuard`,
  `adminAreaGuard` — applied per route, including per-capability on
  individual admin-area routes.
- `NAV_BLUEPRINT` (`core/configuration/navigation.ts`) is filtered by
  permission and `adminOnly` at runtime by `NavigationService`, so the menu
  is already role-derived rather than hardcoded per role.
- A design token layer exists: `styles/_tokens.scss`, `_gymly.scss`,
  `_bootstrap-vars.scss`, plus `_adminlte.scss` and `_marketing.scss`.
- Every component has a `.spec.ts` alongside it.

---

## 8. What is already strong

1. Tenancy derived server-side from the token; `company_id` from the client
   is never trusted, and the member path validates it against memberships.
2. Capability catalogue + editable company-scoped roles — the moderator /
   coach / moderator distinction is data, not `if role == "x"`.
3. Plan definition separated from member subscription state, with a
   many-to-many plan↔activity join already in place.
4. Capacity, session format and coach conflicts enforced at the model and
   database level.
5. Activities are rows, not columns. No `is_boxing` / `is_pilates` anywhere.
6. Four separate role shells on the frontend with per-route capability guards.
7. Services layer, serializers, audit log, notifications, 101 backend specs
   including cross-tenant request specs.

---

## 9. Gaps, debt and risks

### 9.1 Structural gaps against the configurable-engine target

| # | Gap | Evidence | Severity |
|---|---|---|---|
| G1 | **No `companies.settings` JSONB.** Configuration is a scatter of typed columns (`business_hours_start/end`, `working_days`, `primary_color`, `locale`, `timezone`). There is nowhere to put booking rules (`cancellation_hours`, `online_booking`) without a migration per rule. | `db/schema.rb` `companies` | High |
| G2 | **No `spaces` table.** Sessions have no room. A studio with two rooms cannot run two concurrent sessions distinguishably, and nothing prevents overbooking a physical room. Deliberately removed earlier ("a Company is the venue") — the multi-room business types in the new brief reverse that call. | no model, no column | High |
| G3 | **`contracts.activity_id` is NOT NULL** — a member subscription is bound to exactly one activity, even though `ContractType` supports many through `contract_type_activities`. A multi-activity plan cannot be sold as one contract. | `db/schema.rb` `contracts` | High |
| G4 | **No moderator shell.** The moderator logs into the *admin* shell with items filtered out. The front-desk workflow (search → check-in → book → take payment) is not a screen. | `app.routes.ts`, no `features/moderator` | High |
| G5 | **Coach area is one page** (`/coach/today`). No schedule, member list, attendance-taking, or session detail. | `features/coach/` | High |
| G6 | **Member portal is three pages** (schedule, bookings, profile). ~~No subscription view, no remaining-sessions display, no booking history~~ — **this was wrong**: the profile page already shows the subscription, remaining sessions, attendance rate and recent history. The real gap was gym switching: the app read `gyms[0]`, so someone with two memberships could only reach one. Fixed in Phase 6. Notifications remain missing. | `features/member/` | Medium |
| G7 | **Onboarding is a dismissible checklist**, not the seven-step guided setup (company → activities → spaces → plans → staff). | `onboarding_controller.rb` | Medium |
| G8 | **No booking/cancellation rule engine.** Cancellation windows, online-booking on/off and waitlists have no representation. | grep: absent | Medium |

### 9.2 Debt

| # | Item | Note |
|---|---|---|
| D1 | **Dual role system.** `staff_members.role` (integer enum) *and* `staff_members.role_id` → `Role`, kept in sync by a `before_validation` hook. Two sources of truth for the same fact. | Collapse onto `Role`. |
| D2 | **`ModuleCatalog` is dead weight.** Every company has every permission; `permissions_for` ignores its argument and the `mod_*` columns are gone. | Delete or repurpose as the feature-toggle map (G1). |
| D3 | **`companies.locations_count`** — counter for a deleted table. | Drop. |
| D4 | **Naming drift.** `ContractType`/`Contract`/`ContractPeriod` for what the product, the brief and the UI all call plans and subscriptions. Frontend routes say `/admin/contracts/plans` and `/admin/contracts/activities` — activities nested under contracts is a taxonomy accident. | Rename in one deliberate pass or not at all. |
| D5 | **`platform_settings`** holds a single integer (`annual_discount_percent`) in a full table. | Fine, but note it. |
| D7 | **`revenue` was missing from `ModuleCatalog::ALL_PERMISSIONS`.** `Permissions::Resolve` intersects a role's permissions with that list, so `revenue` was silently stripped from every permission list the API advertised — including the admin's. Latent, not live, because no frontend guard read it yet. Fixed in Phase 3. | Fixed. |
| D6 | **Admin bypasses every capability check** (`capability? → true if admin?`). Correct today; it means an audit of capability coverage cannot be done by testing as an admin. | Keep, document. |

### 9.3 Security items to verify in Phase 4 (not yet confirmed as bugs)

- **Correction (found during Phase 3):** a custom RuboCop cop,
  `Gymly/UnscopedTenantQuery`
  (`lib/rubocop/cop/gymly/unscoped_tenant_query.rb`), already fails the
  build on a bare `Model.find/find_by/where` for any of ~19 tenant-scoped
  models, exempting only `/controllers/api/v1/superadmin/`. It was written after
  a real bug in `BookingsController#set_booking`. So the sweep this section
  called for is largely automated already; what remains is keeping
  `TENANT_MODELS` complete (`Space` and `ActivitySpace` were added in
  Phase 3) and covering the lookups the cop cannot see, such as records
  reached through an association chain.
- `Client` being global means client lookups must be scoped through
  `Membership` on every staff-side endpoint. One unscoped `Client.find` is a
  cross-tenant leak of a real person's record.
- Mass assignment: confirm every controller uses `params.require(...).permit`
  with an explicit list, and that `company_id`, `role`, `role_id`,
  `password_digest` and `active` are never permitted from the client.
- **Correction (found during Phase 4):** Rack::Attack is present and
  thorough (`config/initializers/rack_attack.rb`) — per-IP burst and
  sustained throttles on login, a per-email throttle that is the real
  brute-force defence, plus password resets and registration. This section
  was wrong to say otherwise. The one gap, `email_verifications#create`,
  was closed in Phase 4.
- Active Storage upload validation exists for `logo` (type + size) and
  `HasPhoto`; support-ticket attachments need the same check.
- `GET /support_tickets/:id/attachments/:attachment_id` — verify the
  attachment belongs to the ticket and the ticket to the caller's company.

---

## 10. Honest summary

The codebase is **substantially closer to the target architecture than the
brief assumes**. The configurable engine largely exists: activities are
rows, capacity is per-activity, roles are editable data, plans are separate
from member subscriptions, tenancy is derived server-side, and the frontend
already splits four role shells with capability guards.

What is genuinely missing is narrower than a rebuild: a company settings /
rule layer (G1, G8), spaces (G2), multi-activity contracts (G3), and three
under-built role experiences (G4, G5, G6). Plus the debt in §9.2 and a
systematic IDOR sweep in §9.3.

The recommendation that follows from this analysis is **targeted
transformation, not rewrite**. A rewrite would discard working DB-level
invariants (the coach exclusion constraint, the held-booking partial index,
the `remaining_bookings` check), a 101-file spec suite, and a permission
model that already does what the brief asks for.
