# Gymly — Target Architecture

Companion to `CURRENT_ARCHITECTURE.md`. Written 2026-09-19.

## 0. Decisions taken

These were decided explicitly and are not open:

| Decision | Choice | Consequence |
|---|---|---|
| Backend strategy | **Full rewrite of the domain layer** | Models, services, controllers and serializers are rebuilt against a redesigned schema. Data migrates forward (see `MIGRATION_PLAN.md`). |
| Spaces | **Optional per company** | `spaces` exists; a company turns it on in settings. Session creation only asks for a room when it is on. |
| Naming | **Keep `Contract` / `ContractType` / `ContractPeriod`** | No rename pass. The product still *says* "plan" and "subscription" in the UI; the domain keeps its current words. `Subscription` continues to mean the gym's own SaaS subscription to Gymly. |
| UI | **Full redesign of every screen** | All four existing shells are rebuilt, plus a new moderator shell. |
| Business logic (2026-10-02) | **On the models, no service layer** | Each rule is a model method (`Session#book!`, `Contract.sell!`, …); controllers read like CRUD. Supersedes the "services" layer in §1 and §4 as first written. |

Three database-level invariants are carried forward verbatim into the new
schema, because they are correctness properties the application layer cannot
cheaply reproduce:

1. `sessions` GiST exclusion on `coach_id + tsrange(starts_at, ends_at)` — a
   coach cannot be in two scheduled places at once.
2. `bookings` partial unique index on `(session_id, client_id) where status = held`.
3. `contract_periods` check constraint `remaining_bookings >= 0`.

To which the rewrite adds a fourth, for spaces (§3.2).

## 1. Shape

Unchanged and deliberate: a **Rails monolith + Angular SPA + PostgreSQL +
Redis**. No microservices, no event bus, no CQRS, no generic repository
layer, no workflow engine. The brief's §31 governs; where this document and
ambition disagree, §31 wins.

```
Angular SPA (5 shells)
      │  JWT, /api/v1
Rails API  ── controllers (thin) ── models (invariants + business rules)
      │
PostgreSQL          Redis (Sidekiq, ActionCable)
```

## 2. The configuration layer — the core of "configurable engine"

The engine reads behaviour from **`companies.settings` (JSONB)**, wrapped by
a typed Ruby object. Nothing reads the raw hash.

```ruby
company.settings          # => CompanySettings, not a Hash
company.settings.booking.cancellation_hours   # => 2
company.settings.feature?(:spaces)            # => false
```

`CompanySettings` is a plain object with a declared schema, defaults, a
`to_h`, and validation on write. Unknown keys are dropped on save — the
configuration surface is closed, not free-form. This is the answer to the
brief's §29 "controlled customization": the *values* are per-company, the
*keys* are code.

```ruby
# app/models/company_settings.rb  (shape, not final)
FEATURES = %i[bookings spaces attendance revenue reports online_booking waitlist].freeze

BOOKING = {
  cancellation_hours: 2,        # 0 = cancel any time up to start
  online_booking:     true,     # members may book themselves
  booking_opens_days: 14,       # how far ahead the schedule is bookable
  waitlist:           false,
  no_show_consumes_session: true
}
```

Rule, enforced in review: **business entities are relational tables;
configuration is JSONB.** A member, a booking, a payment, a space is never a
JSON blob. A cancellation window never becomes a column.

Feature flags do **not** gate authorization. A disabled feature hides
navigation and rejects the write at the service layer with a clear message;
permissions remain a separate, orthogonal check (see `PERMISSIONS.md`).

## 3. Structural changes to the domain

### 3.1 Company settings replace scattered columns

`business_hours_start`, `business_hours_end`, `working_days`,
`primary_color` move into `settings` under `hours` and `branding`.
`locations_count` is dropped. `timezone`, `currency`, `locale`, `slug`,
`active` stay as columns — they are queried and constrained, not configured.

### 3.2 Spaces (optional)

```
spaces: id, company_id, name, kind, capacity, active, settings, timestamps
sessions.space_id → spaces.id  (nullable)
activities ←→ spaces            (join: activity_spaces, optional)
```

New invariant, mirroring the coach one:

```sql
EXCLUDE USING gist (space_id WITH =, tsrange(starts_at, ends_at) WITH &&)
  WHERE (status = 0 AND space_id IS NOT NULL)
```

A room cannot host two scheduled sessions at once — enforced in the
database, for the same reason the coach rule is.

When `settings.feature?(:spaces)` is false, the column stays null, the UI
never shows a room field, and nothing breaks. This is what "optional per
company" means concretely: one flag, one nullable FK, one conditional
constraint — not a parallel code path.

### 3.3 Multi-activity contracts

`contracts.activity_id` becomes **nullable**, with this meaning:

- `activity_id` present → the contract is for that one activity.
- `activity_id` NULL → the contract covers **every activity on its
  `ContractType`** (via `contract_type_activities`).

This satisfies the brief's "do not assume one subscription = one activity"
without inventing a second join table, and it makes the existing
single-activity rows valid as-is under the new rule. Access checks read
`Contract#covers_activity?(activity)` — one method, both cases.

### 3.4 One role system

`staff_members.role` (integer enum) is removed. `staff_members.role_id` →
`Role` is the single source of truth. `Role#key` keeps identifying built-ins
(`admin`, `moderator`, `moderator`, `coach`) for the shell routing, and
`ModuleCatalog` is deleted.

### 3.5 Waitlist

`bookings.status` gains `waitlisted`; `bookings.waitlist_position` (integer,
nullable). Promotion on cancellation happens in the same transaction
(`Session#promote_from_waitlist!`), not a background job, and only runs when
`settings.feature?(:waitlist)`.

## 4. Layering rules

| Layer | May contain | Must not contain |
|---|---|---|
| Model | validations, DB-backed invariants, associations, scopes, predicates, and the business rules as methods (`Session#book!`, `Booking#cancel!`, `Contract.sell!`, `Payment.collect!`) — locks and transactions included | HTTP concerns, policy decisions |
| `app/lib` | what is not a business rule: PDFs, spreadsheets, dashboard figures, CSV import/export, JWT, the SMS client | request params, rendering |
| Controller | authn/authz gating, param permitting, calling one model method, rendering one serializer | business rules, conditionals over roles |
| Serializer | shape of the response for one audience | queries (accept preloaded records) |

A rule a request breaks raises `ApplicationRecord::Refused` with the reason;
`ApplicationController` answers it with a 422, the same shape as a failed
validation. A controller action longer than ~15 lines means a model method is
missing.

## 5. Tenancy

Unchanged in principle, tightened in enforcement. `current_company` is
derived from the token. Additionally, the rewrite introduces a **mandatory
scoping helper** so that scoping is the default rather than a thing each
author remembers:

```ruby
# Api::V1::BaseController
def company_scope(relation) = relation.where(company_id: current_company.id)
def find_in_company!(relation, id) = company_scope(relation).find(id)
```

and for the global `Client`:

```ruby
def find_member!(id)
  current_company.clients.find(id)   # through memberships — never Client.find
end
```

A spec (`spec/architecture/scoping_spec.rb`) greps the controller sources and
fails on any bare `Model.find(params[:id])` for a company-owned model. Rules
that are only conventions rot; this one is tested.

## 6. Five audiences, five shells

| Audience | Principal | Backend namespace | Shell |
|---|---|---|---|
| Platform superadmin | `User#superadmin?` | `/api/v1/superadmin/*` | `/superadmin` |
| Admin | `User#admin?` | root + `/admin/*` | `/admin` |
| Moderator | `StaffMember` on a role with desk capabilities | root | `/desk` **(new)** |
| Coach | `StaffMember` on the `coach` role | root + `/coach/*` **(new)** | `/coach` |
| Client | `Client` | `/me/*` | `/member` |

The moderator stops borrowing the admin shell. The coach gets its own
read-mostly namespace so coach endpoints can be audited as a unit rather
than as capability exceptions scattered through the staff controllers.

## 7. What gets deleted

`ModuleCatalog`, `staff_members.role`, `companies.locations_count`,
`platform_settings` as a table (folded into a Rails credential/ENV-backed
constant — one integer does not need a table), and any controller action
with no frontend caller (audited in Phase 3).

## 8. Non-goals

- No multi-currency per company (one currency per company stays).
- No per-activity cancellation policies in v1 — company-level only.
- No recurring billing automation; invoicing stays manual, as today.
- No public marketplace/directory work beyond what already exists.
