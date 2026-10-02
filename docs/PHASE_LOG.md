# Gymly — Transformation Progress Log

Running record of what is actually done, so any session can resume without
re-deriving state. Update it at the end of every work block.

Test baseline before any of this work: **705 examples, 0 failures.**

---

## Phase 1 — Analyse ✅ (2026-09-19)

`CURRENT_ARCHITECTURE.md`. Key finding: the codebase was substantially closer
to the target than the brief assumed.

## Phase 2 — Design ✅ (2026-09-19)

`TARGET_ARCHITECTURE.md`, `DOMAIN_MODEL.md`, `PERMISSIONS.md`,
`DATABASE_DESIGN.md`, `API_DESIGN.md`, `UI_ARCHITECTURE.md`,
`MIGRATION_PLAN.md`.

Four decisions taken by the product admin, recorded in
`TARGET_ARCHITECTURE.md` §0: full domain rewrite, spaces optional per
company, keep the Contract/ContractType/ContractPeriod names, full UI
redesign.

## Phase 3 — Backend core 🔶 in progress

### Done — suite green at **789 examples, 0 failures**, rubocop clean

**Migrations applied** (all additive and reversible):

| # | Migration | Effect |
|---|---|---|
| 01 | `LetACompanyConfigureItself` | `companies.settings` jsonb + GIN index |
| 04 | `GiveACompanyItsRoomsBack` | `spaces`, `activity_spaces` |
| 05 | `PutASessionInARoom` | `sessions.space_id` + `no_overlapping_space_sessions` GiST exclusion |
| 06 | `LetOneContractCoverEveryActivity` | `contracts.activity_id` nullable |
| 07 | `HoldAPlaceInTheQueue` | `bookings.waitlist_position` + check constraint |

**The configuration engine**

- `CompanySettings` — typed, immutable, closed-schema value object over the
  JSONB. Unknown keys dropped on write and reported via `#unknown_keys`;
  booleans cast from what forms and JSON actually send; integers clamped to
  range rather than rejected. `Company#settings`, `#settings=`, `#feature?`.
- Sections live today: `features` (7 flags), `booking` (3 rules). `hours` and
  `branding` join in migration 02, which is destructive and deferred.

**Spaces** — `Space`, `ActivitySpace` models; `SpaceSerializer`;
`Api::V1::SpacesController` (full CRUD, feature-gated 404, capability-gated
writes, activity restriction sync scoped to the company's own activities);
`resources :spaces` routed. Deleting a room deactivates it while sessions
remain and deletes it once nothing upcoming needs it; past sessions keep
their history with the room unset.

**Multi-activity contracts** — `Contract#covers_activity?`, `#all_access?`,
`#covered_activities`. `ContractType#price_for(nil)` answers the all-access
price (dearest covered activity). `#grants_access_to?` now nil-safe.

**Booking rules, driven by settings** — `online_booking`,
`booking_opens_days` and `cancellation_hours` enforced in
`Bookings::Create` / `Bookings::Cancel`, applied to members (`by: :member`)
and deliberately not to staff. `Bookings::PromoteFromWaitlist` added;
waitlist join, ordering, promotion and resequencing all behind the
`waitlist` feature flag.

**Permissions** — added `spaces` and `settings` capabilities.

**Fixed along the way**

- `revenue` was missing from `ModuleCatalog::ALL_PERMISSIONS`, so
  `Permissions::Resolve` silently stripped it from every advertised
  permission list including the admin's. Latent (no frontend guard read it
  yet); would have broken Phase 6.
- A flaky spec: `expect(response.body).not_to include("240")` in the member
  profile spec matched random UUIDs. Now asserts on parsed values.
- `Gymly/UnscopedTenantQuery` cop taught about `Space` and `ActivitySpace`.

**Reverted deliberately** — a `Contract` validation requiring its activity to
be covered by its plan. Correct at the point of sale, but it would make every
contract un-saveable (including un-cancellable) the moment an admin removed
an activity from a plan. Coverage is enforced at booking time instead.

## Phase 3 — Backend core ✅ complete

All nine planned migrations are applied (09 withdrawn — see below). Suite
**862 examples, 0 failures**; rubocop clean; frontend 1179 passing.

### Destructive migrations, done

| # | Migration | Effect |
|---|---|---|
| 02 | `MoveTheOpeningHoursIntoTheSettings` | hours, working days, brand colour backfilled into `settings`, then the four columns dropped |
| 03 | `ForgetTheSitesWeNoLongerHave` | `companies.locations_count` dropped |
| 08 | `GiveAStaffMemberOneRoleNotTwo` | `staff_members.role` enum dropped, `role_id` NOT NULL |
| 09 | — | **withdrawn** |

**Migration 09 was a design error and is withdrawn.** It proposed folding
`platform_settings` into an ENV-backed constant. But `annual_discount_percent`
is edited at runtime by a platform superadmin through
`PATCH /api/v1/superadmin/subscription_pricing` — a constant would have deleted a
working feature. A single-row settings table is the right shape for an
superadmin-editable global. `DATABASE_DESIGN.md` §3 and `MIGRATION_PLAN.md` are
corrected.

### Notes on the destructive work

- **The API did not change.** Hours and branding moved storage only: the
  serializer still emits `business_hours_start`, `business_hours_end`,
  `working_days` and `primary_color` at the top level, the controller still
  accepts them there, and `Company` keeps readers and writers for each. No
  Angular change was needed.
- **Validation moved with the data.** `CompanySettings` coerces anything
  unusable to its default and records it in `#invalid_values`; `Company`
  turns that into validation errors, so a bad hex colour is still a 422
  rather than a value that silently vanishes.
- **A staff member's "kind" became a fact about them.** The dropped enum
  carried two things: permissions (now the Role's job) and whether the login
  coaches. The second moved to `coach_id.present?` — which the five
  coach-narrowing checks already read. Consequence: an admin can now put a
  coach on a custom role and they still reach the coach shell. The API sends
  `role_key` and `is_coach` instead of `role` and `staff_role` meaning the
  same thing twice; the Angular guard and auth service follow.
- **`ModuleCatalog` kept, reduced.** It held a second copy of the permission
  catalogue that `Permissions::Resolve` intersected every role against —
  the direct cause of the `revenue` bug. It is now only the "what your
  subscription includes" display list.

## Phase 4 — Authorization & tenant isolation 🔶 in progress

### Done

- **`spec/requests/security/`** — 59 examples across three files:
  `tenant_isolation_spec.rb` (33), `role_boundaries_spec.rb` (22),
  `impersonation_spec.rb` (4). Every example is a denial.
- **Member tokens are refused on staff endpoints explicitly**
  (`BaseController#reject_member_token!`). Previously incidental, via
  `require_company!` rendering 422 — and a controller whose capability check
  ran first would have raised on `current_user.admin?` with a nil user.
- **Impersonation is auditable throughout the session**, not just at its
  start, via `Current.impersonator` read by `AuditLogs::Record`.
- **`email_verifications#create` throttled** — the one unauthenticated
  account-mail endpoint with no ceiling.

### Corrections to the Phase 1 analysis, found by doing the work

1. A tenant-scoping RuboCop cop (`Gymly/UnscopedTenantQuery`) already
   existed and fails the build on bare `Model.find` for ~19 models. Phase 1
   called for building one. `Space`/`ActivitySpace` were added to it.
2. Rack::Attack already existed and was thorough. Phase 1 said there was no
   evidence of it.
3. `revenue` was missing from `ModuleCatalog::ALL_PERMISSIONS`, silently
   stripped from every advertised permission list including the admin's.
   Latent only because no frontend guard read it yet.

### Also done

- **`spec/requests/security/foreign_ids_spec.rb`** (9 examples) — the cases
  the cop cannot see, where a foreign id arrives inside a nested write: a
  coach, a role, an activity, a room or an attachment belonging to another
  gym. All nine passed first time; the defences (scoped lookups and
  same-company model validations) were already in place.
- **`spec/architecture/strong_params_spec.rb`** (8 examples) — reads the
  controller sources, so a new controller is covered the day it is written.
  Asserts no controller permits `company_id`, `password_digest`,
  `token_version`, the verification/reset token digests, or any real counter
  cache column, and that no controller resolves a company from params.
  Counter caches are read from the associations that declare them, not
  guessed from names ending in `_count` — `contract_types.session_count` is
  a field an admin sets, not a cache.
- **Support ticket attachments verified** — `@ticket.attachments.find` under
  a `current_company`-scoped ticket. The Phase 1 doc flagged this as
  unverified; it was already correct.

Phase 4 total: **68 security examples**. Suite **879 examples, 0 failures**.

### Remaining in Phase 4

Nothing blocking. Two things deliberately deferred to the phase that needs
them:

- Per-endpoint capability coverage for the `/coach/*` and `/desk` surfaces,
  which do not exist yet (Phase 6).
- The `settings` capability is defined and enforced on nothing yet — the
  company settings endpoints still gate on `require_admin!`. It gets wired
  when the settings UI is built (Phase 8).

## Phase 5 — Frontend architecture 🔶 in progress

### Done

- **The desk shell exists** (`layout/desk-shell/`, `features/desk/`). The
  moderator stops borrowing the admin shell. Search-first: the member
  search is the top of every desk screen, focused on load (skipped on touch),
  debounced at 250ms, minimum two characters.
- **`features/desk/dashboard`** — the session under way, two counts (expected
  / turned up), what is still to come, memberships about to lapse, new
  members. No totals, no revenue, no charts.
- **`features/desk/checkin`** — today's sessions only, `?session=` preselects
  one, and a stale id falls back to the picker rather than an empty roster.
- **`deskAreaGuard`** — requires `checkin` AND `bookings` (checkin alone is a
  coach), turns away coaches, admins and superadmins, and honours the trial lock.
- **`AuthService#deskShellApplies`** sends desk staff to `/desk/dashboard`
  after login.
- **`_adminlte.scss` renamed to `_shell.scss`.** Nothing in it was SuperadminLTE.
- 26 new frontend examples; suite **1210 passing**, lint clean, builds clean,
  i18n complete in fr/en/ar (775 keys).

### Deliberately deferred

**The `_gymly.scss` decomposition is NOT done, and the "under 250 lines"
target in `UI_ARCHITECTURE.md` §1 is wrong as written.** That file is mostly a
Bootstrap *override* layer — it restyles `.btn`, `.form-control`, `.table`,
`.alert`, `.badge` with Gymly tokens, and those classes are used across 49
templates. It cannot be scoped to components or shrunk while the templates
still use Bootstrap classes. Splitting it cosmetically now and rewriting it
again in Phase 7 would be wasted work, so it moves to Phase 7, where the
templates are rewritten anyway.

### The planned primitives, reconsidered

`UI_ARCHITECTURE.md` §5 listed six to add. Four are not being built, and the
doc is corrected:

| Primitive | Verdict |
|---|---|
| `stat-tile` | **Dropped** — `kpi-card` already is this. |
| `sheet` | **Dropped** — `drawer` already is this, with a focus trap. A bottom placement would be an input on it, not a new component. |
| `segmented-control` | **Dropped** — no screen asks for one. `status-filter` covers the rail case. |
| `date-range-picker` | **Deferred** — speculative until a screen needs it. |
| `data-table` | **Deferred to Phase 7.** Today's list pages carry rich per-cell content (avatars, highlight pipes, badges); a column-config table would fight that. It belongs with the rewrite that will consume it. |
| `entity-card` | **Deferred to Phase 7** for the same reason — the desk and coach lists each needed a slightly different shape, and generalising from two is guessing. |

Building primitives with no consumer is the overengineering the brief's §31
warns about. They get built when a screen asks.

## Phase 6 — Role dashboards 🔶 in progress

### Done

- **`GET /api/v1/coach/members`** (`Api::V1::Coach::MembersController`) —
  everyone with a live booking on this coach's own sessions, with
  `last_seen_at` / `next_session_at`. 12 request specs.
- **`features/coach/members`** — the coach's own roster, searchable, with an
  "away" flag on anyone three weeks absent and nothing booked.
- **The coach shell's top bar follows the route** instead of always reading
  "Today".

**The `/coach/*` namespace in `API_DESIGN.md` §3 is mostly withdrawn.** It
proposed `/coach/sessions`, `/coach/sessions/:id` and
`/coach/sessions/:id/attendance`. All three already exist, narrowed to the
coach's own sessions, in `SessionsController#base_scope` and
`AttendanceController#accessible_sessions`. Building parallel endpoints would
duplicate the narrowing and give it a second place to be wrong. Only
`/coach/members` was genuinely missing.

Suite: backend **891 examples, 0 failures**; frontend **1217 passing**.

- **All-access contracts stopped crashing everything that read them.**
  Making `contracts.activity_id` nullable in Phase 3 created a contract with
  no activity without auditing the four places that read
  `contract.activity.name`: the contract serializer, the CSV export, the
  receipt PDF and the member's own app. All four would have raised
  `NoMethodError` on the first all-access membership sold. `Contract#activity_label`
  is now the single answer to "what is this for, in words", and
  `spec/requests/api/v1/all_access_contracts_spec.rb` walks a real one
  through each path — reverting the serializer fix makes two of them fail
  with the original error, which is the only reason to trust them.
- **A member can reach the second gym they belong to.** The member app read
  `gyms[0]` everywhere, so a person with two memberships could only see one.
  There is a switcher in the shell now, the choice is remembered, a stale
  remembered gym recovers instead of 404ing the app shut, and the schedule
  reloads when the active gym changes.

**`/me/contracts`, `/me/attendance` and `/me/companies` from `API_DESIGN.md`
§3 are not needed.** `GET /me/profile` already returns the subscription (with
`remaining_bookings`), the attendance rate and recent history, and the list
of gyms. Phase 1 recorded the member portal as missing all of this; it was
wrong. What was genuinely missing was the ability to *use* the gym list.

Suite: backend **900 examples, 0 failures**; frontend **1226 passing**.

- **The platform superadmin has a dashboard.** `GET /api/v1/superadmin/metrics` +
  `/superadmin/overview`, and the console lands there rather than on the companies
  table. Six numbers, each with a decision behind it; the one that matters
  most is `companies_with_activity` — how many gyms actually ran a session in
  30 days, the difference between a product being bought and being used.
  13 request specs, 9 component specs.

  Two numbers refuse to lie when they have nothing to say: the signup trend
  is null in a first month rather than reporting +100% against zero, and the
  in-use share is null with no gyms rather than dividing by zero.

  Writing `locked` as its own count exposed a gap — a company with no
  subscription row appeared in neither `open` nor `locked`. It is the
  remainder of `total - open` now, so the two always add up, matching how the
  company list already treats a missing subscription.

Suite: backend **913 examples, 0 failures**; frontend **1234 passing**.

### Remaining in Phase 6

- Coach: a week schedule view and a session-detail/roster screen (today's
  page covers the day; the week does not exist).
- Member portal: remaining sessions as the *headline* number rather than a
  muted line — a design change, so Phase 7.
- Admin dashboard: exceptions-first rather than a wall of statistics. The
  `attention` rows already exist in the dashboard payload; this is about what
  the page leads with, so it is largely Phase 7 too.

### A slip worth naming

Angular's `as` binding is only legal on a *primary* `@if`, never on an
`@else if`. I wrote `} @else if (x; as y) {` three times across the desk,
check-in and superadmin screens. The build catches it every time; the unit tests
do not, unless the component has a spec that compiles its template. Worth
remembering when writing a new screen's shell.

## Phase 7 — UI redesign 🔶 in progress

### Done — the foundation

**Bootstrap is gone.** `_gymly.scss` had already restyled `.btn`,
`.form-control`, `.table`, `.alert`, `.badge` and the tabs to the last rule,
so the app shipped a 420 kB stylesheet whose every visible declaration it
then overrode. What was genuinely still coming from the framework was a
bounded set of layout utilities plus five components nobody had themed —
which is why those five were the only places the old look still showed.

- `styles/_utilities.scss` — the utilities against Gymly's tokens, keeping
  Bootstrap's class names because 49 templates already say them. Spacing maps
  onto the token scale (`mb-3` is `--space-3`); sides are logical properties,
  so RTL comes free.
- `styles/_leftovers.scss` — input groups, spinner, progress, responsive
  table wrapper, colour input, checkbox row, tab list, compact table,
  warning button.
- **Stylesheet: 420.11 kB → 171.03 kB.**

**`scripts/check-css.mjs`** is what made that safe. Same shape as
`check-i18n.mjs`: every class a template asks for must have a rule behind it,
or the build fails. A missing rule is invisible until someone opens the
screen. It found **eight classes that had been styling nothing**:
`app-navbar-brand-text`, `app-navbar-menu`, `dashboard-setup-card`,
`fx-dashboard`, `fx-label`, `fx-session-tip-fill`, `is-video`,
`notif-detail`. Wired up as `npm run check:css`.

**`_gymly.scss` is decomposed** — thirteen partials grouped by concern, split
by a script against the file's own section markers, asserting every section
landed somewhere. Compiled output is byte-identical: this moved rules, it did
not change them.

The `UI_ARCHITECTURE.md` §1 target of "under 250 lines" is met in spirit
rather than literally: no single file is over 174 lines, and the global layer
is now findable. A single 250-line file was never the goal; being able to
open one component's rules was.

Frontend: **1234 passing**, lint clean, 919 classes all defined.

### Done — the screens

**Admin** — dashboard (exceptions first, five KPI cards to one footer line),
members (7 columns to 4), member profile (4 tabs to a banner and one
timeline), planning (coachless sessions visible where they get fixed),
catalogue (plans and activities composed onto one page), team (roles in
plain words), subscriptions/payments/bookings (shared header, duplicated
counts removed), settings (booking rules UI — the configuration engine had
none).

**Member** — remaining sessions is the page's headline, not its third muted
line.

**Coach** — the session under way, or the next one, above the day's list,
with the one action a coach takes. Session rows became real buttons.

**Superadmin** — overview added; companies, pricing, support and updates took the
shared header.

**One header across the product.** Twelve components were importing
`PageHeaderComponent` without rendering it by the end.

### Scaled back on purpose

- **Planning** stayed on FullCalendar. The maquette drew a hand-built grid;
  replacing it would cost month/day views, drag-to-move and timezone
  handling already fixed once. The two ideas worth having fit in its event
  renderer.
- **Catalogue** is composed, not merged — one component with two CRUD forms
  is the giant screen this work is undoing.
- **Settings** was not rebuilt. The maquette drew a tile hub; the real page
  is a rail that redirects to its first section, and a hub is worse for
  someone editing several sections in a row.
- **Payments, subscriptions and bookings keep tables.** A member became a
  row because a member is a person with a state; an amount, a method and a
  date are columns.

### What removing Bootstrap cost, and what caught it

Four regressions, every one found by the user looking at the screen rather
than by a check:

1. **Buttons unstyled** — the rules set `--bs-btn-*`, Bootstrap's variables,
   read by nothing once it left. Guard added: no `--bs-*` may remain.
2. **Fields borderless** — the rules set only what differed from Bootstrap's
   base (`border-color` with no `border`). No automated catch; needed eyes.
3. **The element reset went with it.** `<dl>`/`<dd>` margins spread a stats
   bar, heading margins pushed a count into a button, `<fieldset>` grew a
   border. Now `styles/_reset.scss`.
4. **A behaviour hook deleted as an unstyled class.** `.app-navbar-menu` is
   what `closest()` reads to tell a click inside the menu from one outside;
   without it every navbar dropdown shut in the same tick it opened. Guard
   added: a class the code reaches for must appear in a template.

The common thread: `check-css.mjs` proves a *name* exists, never that
anything *renders*. It says so in its own comments, and three bugs still
walked through that gap.

Frontend **1270 passing**, backend **935**, lint clean, 954 classes defined,
i18n complete in fr/en/ar.

### Remaining in Phase 7

Nothing blocking. The superadmin company-detail page (265 lines) is the largest
screen not revisited; it is internal-facing and works.

## Phases 8–10 — not started

See `MIGRATION_PLAN.md` §4.

## Phase 8 — Onboarding & configuration ✅

**Done when:** a new company configures itself with no developer involvement.

### The flow

`API_DESIGN.md` §4 specified a resumable, server-tracked setup. What shipped
follows it with one deliberate difference: **nothing that can be derived is
stored.**

`OnboardingStep` is the catalogue (company → activities → spaces → plans →
staff), code-defined like `Permission`. `Onboarding::State` reads the
company's own data for every step it can — does it have an activity, a plan,
a room, anyone on staff — and `settings.onboarding` holds only the two
answers no table can give: a step confirmed by hand, and a step declined.

That is what makes it resumable rather than merely remembered. Create an
activity from the catalogue page in another tab and the step is done, because
the step *is* "this company has an activity". The old `setup_state` had the
same instinct for three flags; this extends it to the whole flow and adds the
part it lacked — a step you can decline.

`company` is the one step nothing in the database can confirm: a company is
created with a name, a currency and default hours, so "the admin has looked
at these" has to be said out loud. It is the only step `PATCH /onboarding`
accepts, and the only reason that endpoint exists.

`spaces` is not skipped for a gym with one room — it is **absent**. A step
whose feature is off does not appear, is not counted, and does not hold
`complete` back. Turning rooms on later puts it back and the flow reopens.

Endpoints: `GET /onboarding`, `PATCH /onboarding`, `POST /onboarding/skip`,
`POST /onboarding/dismiss`. Admin-only — the steps' own work happens on its
own endpoints behind its own capability checks; nothing is written here but
progress.

### Rooms had no UI at all

Phase 3 built `Space`, the exclusion constraint, the controller, the
serializer and the specs. Nothing in Angular ever reached them. A gym could
turn rooms on in Settings and then had nowhere to name one — the acceptance
criterion for this phase failed on a screen that did not exist.

`/admin/spaces` now exists, on the Phase 7 list pattern. The form asks for
*restrictions*, not permissions: a room with nothing ticked takes any
activity, which is what most rooms do, so the common case is the empty one.

### Features reach every role now

The nav entry for rooms needed to know whether the tenant had rooms on, and
the bootstrap payload only carried `settings` to the admin. Staff got `nil`,
so a moderator with the `spaces` capability would never have seen the
entry.

`features` is now its own key in the bootstrap payload, sent to everyone, and
`AuthService#hasFeature` is the one way the frontend asks. It answers what the
product **offers** here; `hasPermission` answers who may use it. Both are
asked, and both are asked again on the backend — `featureGuard` only spares
someone an empty screen, and `SpacesController` still answers 404 on its own.

### Renames

`Company#setup_state` → `Company#onboarding_state`; the bootstrap payload's
`setup` → `onboarding`. `SetupChecklistComponent` and the `getting-started`
page are gone, replaced by `OnboardingStepsComponent` (shared by the
dashboard card and the flow page) and `/admin/onboarding`; the old route
redirects.

The `onboarding.*` i18n namespace belonged to the *create-a-company* wizard,
which is a different thing entirely. That took its own component's name,
`company_setup.*`, and the flow has the namespace that describes it.

### What caught what

The `as`-on-`@else if` mistake happened once more, in the flow template, and
was fixed the way Phase 7 found: lead with the branch that needs the binding.

Adding `ConfigurationService` to `NavigationService` broke 51 tests at once —
the nav service pulled `HttpClient` into every test bed that stubbed it. The
tests were right: the nav service has no business knowing the configuration
service. It asks `AuthService`, which is where it already asks about
permissions.

Frontend **1295 passing**, backend **951**, lint clean both sides, 959
classes defined, 833 i18n keys in fr/en/ar, build clean.

## Phase 9 — Data migration ✅

**Done when:** counts match; no orphans; a sample company reads correctly in
every shell.

There is no production database to migrate. What this phase delivers is the
rehearsal itself — run end to end on real data — and the tooling that makes
running it against production a mechanical step rather than a judgement call.

### The rehearsal, as actually run

Development dumped with `pg_dump -Fc`, restored into a scratch database, then
rolled **backwards** across all nine Phase 3 migrations and forwards again:

```
9 down   LetACompanyConfigureItself … WriteOutEveryCompanySettings
9 up     same, in order
```

Every one reverted cleanly, including the three the plan calls the point of
no return. Their `down` blocks are not decorative — they were executed
against real rows, and the data came back.

Counts before (old schema): 91 rows, 25 tables. After: 91 rows, 27 tables
(`spaces` and `activity_spaces` are new and empty). Nothing lost.

All four tenants then read back through the app's own serializers and
services without an error.

### The tooling

`Migration::Audit` plus `migration:snapshot`, `migration:verify` and
`migration:spot_check`. The procedure is in `MIGRATION_PLAN.md` §7.

The audit reads with plain SQL, never through the models — a model can only
describe the schema it was written for, and the question is whether the
database agrees. It checks row counts against the snapshot, the schema, the
settings backfill, staff roles, five orphan classes and **nine tenant-boundary
joins**. That last group is the reason the audit exists: no foreign key can
tell that a session is on another gym's activity or that a booking belongs to
someone who is not a member there, and a migration that rewrote a reference
is exactly where that would happen. Those nine are also half of Phase 10's
tenant-isolation evidence, from the data side rather than the request side.

### What the rehearsal found

One real defect, which is the whole argument for rehearsing.

**A company created after the backfill sat on `settings = {}`.** The
migration filled in the companies that existed when it ran; a company created
the next day started empty and read its hours from `CompanySettings`'
defaults. The behaviour was correct — but the column described nothing, and
an audit cannot tell a company using the defaults from one whose hours were
lost.

`Company#normalize_settings` now writes the full declared shape on every
save, and migration 20260920090000 writes out the ones nobody had saved
since. The column says what the settings *are*, and the audit's check means
something.

Backend **959 passing**, rubocop clean.

### Left for the real thing

Steps 1 and 3 of `MIGRATION_PLAN.md` §7 — dumping production, and running the
same sequence against it in one window with the dump retained. Nothing in the
code is waiting on that.

## Phase 10 — Security & testing ✅ (2026-09-24)

Started from an outside audit of the whole backend (the "Gymly backend
audit" doc), then fixed everything it listed. Backend **1,278 examples, 0
failures**, 95.3% lines / 79.6% branches; frontend **1,427 passing**; four
Playwright journeys passing; rubocop, brakeman, bundler-audit, i18n and css
checks clean.

### The hole the security specs could not see

Every one of the 68 security examples was a denial between gyms' *own*
records, and all of them held. The leak was in the one model that is
deliberately not tenant-scoped: `Client`. A second gym that typed an existing
email adopted the person, read what the first gym had written about them
(date of birth, address, emergency contact), could overwrite their email and
password through `PATCH /clients/:id`, and then sign in as them. Confirmed
end to end before the fix, and now `spec/requests/security/member_identity_spec.rb`.

- **Each gym keeps its own copy.** Date of birth, gender, address and
  emergency contact moved onto `Membership` (`KeepEachGymsOwnCopyOfAMember`,
  backfilled to every existing membership — each could already read them —
  with a `down` that restores from the earliest one).
- **The identity is the person's.** Once they sign in, have been invited, or
  train elsewhere (`Client#identity_shared_beyond?`), a gym may fill a blank
  name, email or phone but not change one: a 422 `identity_locked`, never a
  silent drop. The member corrects their own through `PATCH /me/profile`.
- **Staff never choose a member's password.** `POST /clients/:id/invite`
  emails a link; the member sets it at `/auth/accept-invitation`.
- **Leaving works.** `DELETE /clients/:id` takes the gym's copy away and
  cancels upcoming bookings (refused while a subscription runs; payments
  stay); `DELETE /me/account` anonymises the person everywhere
  (`Clients::Anonymise`).

### Also found by doing it

- **Sessions could not be ended.** `users.token_version` existed and nothing
  read it. Tokens now carry it (`tv`); a new password, a deactivation or
  "sign out everywhere" ends every session. Impersonation lasts an hour. The
  WebSocket opens with a 30-second single-use ticket, not the login token.
- **Cancelling a class kept everyone booked into it** and never gave their
  session back (`Sessions::Cancel`). Writing its spec found a second one:
  **leaving a waitlist refunded a session nobody had spent**.
- **Payments could reach another gym's period** for a shared member, by id
  in `POST /payments` and through the CSV import's unscoped
  `current_contract`. Scoped, and `Payment#payable_belongs_to_this_gym`
  holds it at the model. A double click no longer records two payments.
- **Recurring classes landed an hour late** — built in UTC — and had no UI
  and no nightly job. All three fixed; requests and jobs now run in the
  gym's time zone.
- **The deploy config could not have worked:** `DATABASE_URL` spliced a
  `$VARIABLE` into a clear value, which Docker env files never expand. SMTP,
  Sentry and the other secrets were missing, and with no SMTP every signup
  would have waited forever for its confirmation link — production now
  refuses to boot without mail. A nightly encrypted off-site backup
  accessory, and `backup:restore_check` to prove a dump restores.
- Invoice numbers come from an atomic per-year counter; CSV exports escape
  formula cells; login is capped at 50 attempts a day per email.
- Seven list endpoints queried per row — the members page nine times a
  member. All flat now, held by `spec/requests/performance/`.

### Corrections to the audit

- It said missing bank details would print blanks on invoices. They do not:
  `PayoutAccount` falls back to "settle with Gymly" on purpose, so
  `GYMLY_RIB` is only a boot-time warning.
- It proposed locking the name/phone fields in the member edit form. There
  is no such form — `ClientsService.update` has no caller — so the lock lives
  in the API and the member's own profile.

### Roles, renamed and merged (2026-09-24)

- **Labels first:** the gym's admin shows as "Administrateur", Gymly's
  operator as "Super admin".
- **Réception folded into Modérateur.** New gyms get admin, moderator and
  coach. `FoldTheReceptionIntoTheModerator` deleted an unused Réception role
  and kept a used one as a custom role; the next step moved those people to
  moderator.
- **A way up, closed:** `set_login` reset whatever login was attached to a
  coach. A moderator (who manages coaches) could reset a moderator's or a
  full-access login an admin had linked to a coach. Below the admin it now
  only touches coach-role logins. `spec/requests/security/moderator_boundaries_spec.rb`
  covers every way up.

### The words, all the way down (2026-09-24)

The code now says what the product says, in both repos: classes, methods,
the `User` enum, role keys, API namespaces (`/api/v1/superadmin/*`,
`/api/v1/admin/*`), Angular routes (`/superadmin`, `/admin`), folders, file
names, specs, translation keys, comments — the old migrations' included —
and these docs. Gymly's operator took the name superadmin first, and only
then did the gym's role take the name admin, so the word never meant two
things at once.

`CallTheOwnerTheAdmin` carries the stored data across: the column naming a
company's admin, role keys, audit action names and metadata keys, and the
notification deep links. `users.role` is an integer enum, so no user row
moved. Everyone on a Réception role became a moderator — one-way.

A browser holding a session cached before the rename signs in again
(`gymly_user_v2`) rather than reading its old role names with their new
meanings.

### One migration (2026-09-24)

`db/migrate` held 89 migrations: creates, renames, backfills, columns added
and dropped, data moved between roles. None of it had a production database
to carry, so the history is squashed into one migration that only creates —
`CreateGymlySchema`, generated from `schema.rb` and checked by running it
on an empty database: the schema it dumps is identical, and it rolls back to
nothing. It keeps the last version the old history reached, so a database
built from that history counts it as run.

## Two plans, one account, several salles (2026-09-25)

Gymly no longer sells salle-count tiers (Solo 1 / Club 3 / Réseau unlimited).
It sells two plans, per **admin account**, monthly or yearly:

- **Starter** — the whole product, without the member app.
- **Pro** — the member app too, and every system update (a selling point
  on the comparison, not a gate in code).

Decided with the product owner: the plan is the account's (one price
however many salles), and "affecter un ou plusieurs mod à chaque salle"
means **moderators**, not modules.

### What moved

`SellTwoPlansToTheAccount` (reversible; rehearsed down and up on the dev
database, schema identical after):

- `subscriptions.company_id` → `subscriptions.admin_id` (unique) + `plan`.
  An account keeps its oldest salle's subscription; every salle's invoices
  move onto it. Existing accounts go on **Pro** — nobody loses the member app.
- `invoices.company_id` → `invoices.subscription_id`, plus `invoices.plan`
  frozen at issue like the amount. The PDF is billed to the account's first
  salle (`Subscription#billing_company`), which also sets its currency and
  time zone.
- `subscription_prices.company_limit` → `plan` (unique with currency).
  Annual price is still twelve months less `PlatformSetting`'s discount.
- `users.company_limit` dropped: an admin opens as many salles as they like.
  A later salle joins the account — no second trial.
- `staff_members.user_id` is unique per company, not globally.

`Company#subscription` now reads `admin.subscription`, so the lock, the
bootstrap and every caller kept working; locking the account locks every
salle.

### The member app is Pro

`Subscription#member_app?` = Pro or still on the free trial. Enforced on
the backend: a member none of whose gyms offers it cannot sign in
(`403 member_app_not_included`), `/me/*` only sees gyms that offer it
(`BaseController#member_companies`), and `POST /clients/:id/invite` is
refused on Starter. The admin UI greys the invitation out with a Pro hint.

### Several salles

- `User#current_company` is the one answer to "which salle is this login in":
  an admin's switched-to salle, a staff login's current staff record. It is
  never a salle a moderator was withdrawn from, which `active_company`
  alone could still name.
- `GET /companies/network` + `PUT /companies/:id/moderators` —
  `Companies::PostModerators` creates or deletes a salle's staff record,
  on that salle's role with the same key. Coaches are never posted (they
  teach one salle's timetable); a moderator's last salle cannot be taken.
- Staff logins list and switch between their salles (`User#workplaces`).
- Frontend: `/admin/salles` ("Mes salles"), the navbar switcher always
  shown to an admin and to a moderator posted to several, a switcher in the
  desk shell.

### Superadmin

Plan select (Starter/Pro) on the company page, which says it moves the whole
account and lists the account's salles; plan chip on the companies list and
the header; Starter/Pro prices per currency with a live annual preview and
accounts per plan; accounts per plan on the overview. `PATCH
/superadmin/companies/:id/company_limit` is gone.

Backend **1,310 examples, 0 failures**, rubocop clean, OpenAPI regenerated;
frontend **1,447 passing**, lint/i18n/css clean; Playwright smoke 4/4.

### Several salles are Pro (2026-09-26)

Revised with the product owner: **Starter runs one salle**; Pro adds several
salles, the member app and every update.

- `Subscription#multi_salle?` = Pro or still on the free trial (the trial
  shows the whole product, as with the member app). Sent as `multi_salle`
  in `/subscription` and `/bootstrap`.
- `Companies::Open` refuses a salle beyond the first unless the account is
  `multi_salle?`; `POST /companies` answers `403 multi_salle_not_included`.
  The first salle always opens (it opens the account).
- A Starter account that already runs several salles keeps them and still
  switches between them: only opening another is refused.
- Frontend: "Mes salles" swaps "Nouvelle salle" for a locked "Plusieurs
  salles avec Pro" leading to `/admin/subscription`; the subscription page
  lists several salles with the member app and the updates under
  "Uniquement avec Pro", and warns that Starter stops new salles.

## No service layer (2026-10-02)

The 46 domain service objects in `app/services` are gone. Every rule they
held is now a method on the model it is about, with the same locks,
transactions and messages; controllers call one method and render.

| Was | Now |
|---|---|
| `Bookings::Create` / `Cancel` / `PromoteFromWaitlist` / `SendReminder` | `Session#book!`, `Booking#cancel!`, `Session#promote_from_waitlist!`, `Booking#send_reminder!` |
| `Sessions::Create` / `Update` / `Schedule` / `Cancel` | plain `save` / `update` (the coach-overlap constraint becomes a validation error in `Session`), `SessionsController#create`, `Session#cancel!` |
| `Contracts::Create` / `Renew` / `UpdatePeriod` / `Cancel` | `Contract.sell!` (returns the new period), `#renew!`, `#update_current_period!`, `#cancel!` |
| `Payments::Record` / `Refund` | `Payment.collect!`, `#refund!` |
| `Clients::Enrol` / `RemoveFromGym` / `Anonymise` | `Client.enrol!` (+ the sale, in `ClientsController#create`), `#remove_from!`, `#anonymise!` |
| `Companies::Open` / `PostModerators` | `User#may_open_salle?` + `Company.open!`, `Company#post_moderators!` |
| `Invoices::Issue`, `Subscriptions::CloseUnpaid` | `Subscription#issue_invoice!`, `Subscription.close_unpaid!`, `Subscription.start_trial!` |
| `RecurringSchedules::Generate` / `Stop` | `RecurringSchedule#generate_sessions!`, `#stop!` |
| `Attendance::Mark`, `AuditLogs::Record`, `Notifications::Push` | `AttendanceRecord.mark!`, `AuditLog.record!`, `Notification.push` |
| `Coaches::SetLogin`, `Permissions::Resolve`, `Onboarding::State` | `Coach#set_login!`, `User#permission_keys` / `#role_summary`, `OnboardingState` |
| `CheckIns::Create`, `ServiceResult` | deleted (no caller) |

A refused rule raises `ApplicationRecord::Refused`; `ApplicationController`
answers 422 `{ error, errors }`, the shape a failed validation already had.
Endpoints that used to answer `{ error }` alone now also carry `errors`
(additive — both apps read `error`). `ClientsController` keeps its
`{ error, message, errors }` shape.

What was left in `app/services` is not business logic — PDFs, reports,
dashboard figures, CSV import/export, JWT, SMS, `Migration::Audit` — and
moved unchanged to `app/lib` (specs to `spec/lib`). Same constant names.

Every URL, parameter and response is unchanged apart from that `errors`
array, so the frontend and mobile app need nothing. The service specs became
model specs under `spec/models/<model>/`; the request specs did not change
beyond the few that called a service directly.

Backend **1,311 examples, 0 failures** (5 fewer: the dead `CheckIns::Create`
and two plain-ActiveRecord session specs), coverage 95.4% as before, rubocop
clean, OpenAPI regenerated.
