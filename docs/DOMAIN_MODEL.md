# Fitora — Domain Model

Concepts, lifecycles and rules. Table shapes live in `DATABASE_DESIGN.md`.

## 1. Map

```
                       ┌──────────────┐
                       │     User     │ admin | staff | superadmin
                       └──────┬───────┘
                 owns         │        seats
            ┌─────────────────┴──────────────┐
            ▼                                ▼
      ┌──────────┐                    ┌─────────────┐
      │ Company  │◄───────────────────│ StaffMember │──► Role ──► permissions[]
      │ (tenant  │                    └──────┬──────┘
      │ + venue) │                           └──► Coach (when the role is coach)
      └────┬─────┘
           │
   ┌───────┼────────────┬─────────────┬──────────────┐
   ▼       ▼            ▼             ▼              ▼
Activity  Space     ContractType   Membership     Payment / Invoice
   │       │         (the plan)        │
   │       │             │             ▼
   │       │             │          Client ── global person, own login
   │       │             │             │
   │       │   contract_type_activities│
   │       │             │             │
   │       │             ▼             ▼
   │       │          ┌──────────────────┐
   │       │          │     Contract     │  one term: dates · status ·
   │       │          └────────┬─────────┘  balance · payment
   │       │                   │  renewed_from ──► the term before it
   ▼       ▼                   │
  ┌──────────────┐             │
  │   Session    │◄────────────┼──────── RecurringSchedule
  └──────┬───────┘             │
         ▼                     │
   ┌──────────┐  consumes      │
   │ Booking  │────────────────┘
   └────┬─────┘
        ▼
  AttendanceRecord
```

## 2. Concepts

### Company — tenant and venue
The unit of isolation and the business a member walks into. Carries identity
(name, slug, city, country), locale facts (timezone, currency, locale) and
**`settings`**, the typed configuration object that makes the engine behave
differently for a boxing club and an EMS studio (`TARGET_ARCHITECTURE.md` §2).

A `User` may own several companies; `users.active_company_id` says which one
their session is currently operating.

### Activity — what the business sells time in
A row, never a column. `session_format` is the one piece of structure that
matters: `individual` (capacity 1), `small_group` (2–9), `collective` (10+).
The format constrains capacity; that is how EMS's one-person sessions and
boxing's twenty-person classes come from the same table.

### Space — where it happens (optional)
Off by default. When a company enables it, a `Session` may name a room, and
the database refuses two scheduled sessions in the same room at the same
time. An activity may declare which spaces it can run in.

### ContractType — the plan on offer
The sellable thing: billing period, session count (or `unlimited_bookings`),
optional `booking_limit`, `priority_booking`. Covers one or more activities
through `contract_type_activities`, each with its own price.

### Contract — one term of a member's subscription
Binds a `Client` to a `ContractType` at a `Company` for one term: it starts
and ends (`starts_at`/`expires_at`), has a `status`, a `remaining_bookings`
balance, a frozen `base_price`/`discount`/`final_price` and a
`payment_status`. Its `activity_id` is optional: set for a single-activity
subscription, NULL to mean "everything this plan covers" (or `pack_id` for
a pack).

Renewing never stretches a contract: it sells a **new** contract pointing
back at the one it follows (`renewed_from_id`), on the same formule or on
another. A member's history is that chain. `remaining_bookings` is NULL for
unlimited plans and `>= 0` always (DB check).

Until 2026-10-05 the term lived on a separate `ContractPeriod` under a
dateless `Contract`; migration `20261005120000` folded each period into a
contract of its own. The `contract_periods` table is still there, unread,
until a follow-up migration drops it.

```ruby
def covers_activity?(activity)
  return activity_id == activity.id if activity_id
  contract_type.activity_ids.include?(activity.id)
end
```

### Session — a scheduled occurrence
Activity + time window + capacity + optional coach + optional space + price.
Capacity is **snapshotted onto the session**, not read from the activity, so
changing an activity's capacity never retroactively over- or under-books
sessions already on the calendar.

### Booking — a member's seat in a session
May consume a `Contract` (decrementing `remaining_bookings`) or be paid
per-session. Statuses: `held → confirmed → cancelled`, plus `waitlisted`
when the feature is on.

### AttendanceRecord — whether they actually came
One per booking. `checked_in_at`, `checked_out_at`, `status`, `marked_by`.

### Client — the person
**Global**, not company-scoped: one person, one login, many gyms via
`Membership`. This is the single most security-sensitive fact in the model —
every staff-side client lookup must go through the company's memberships.

## 3. Lifecycles

### Contract
```
sold ──► Contract(active)
              │
              ├─ bookings consume remaining_bookings
              ├─ expires_at passes ──► expired
              ├─ renew  ──► new Contract(active, renewed_from: this),
              │             queued behind the chain; formule may change
              └─ cancel ──► cancelled; future bookings released
```

### Booking
```
                    ┌── capacity available ──► held ──► confirmed ──► attended / no_show
request ──► checks ─┤
                    └── full + waitlist on ──► waitlisted ──(seat frees)──► held
```

`held` exists so two people clicking at once cannot both take the last seat:
the partial unique index on `(session_id, client_id) where status = held`
plus a transactional capacity check is the mechanism.

### Session
```
scheduled ──► completed
     └──────► cancelled  (all bookings released, session balances refunded)
```

## 4. Invariants

Enforced in the **database**:

| Invariant | Mechanism |
|---|---|
| A coach is in one scheduled session at a time | GiST exclusion on `coach_id + tsrange` |
| A space hosts one scheduled session at a time | GiST exclusion on `space_id + tsrange` (new) |
| One held booking per (session, client) | partial unique index |
| A session balance never goes negative | check `remaining_bookings >= 0` |
| A client belongs to a company at most once | unique index on `(client_id, company_id)` |
| One staff seat per user | unique index on `staff_members.user_id` |

Enforced in **models**:

| Invariant | Where |
|---|---|
| Capacity matches session format | `Activity#capacity_matches_session_format` |
| `ends_at > starts_at` | `Session` validation |
| A session's space belongs to the same company | `Session` validation |
| A session's coach belongs to the same company | `Session` validation |
| Only a coach-role staff member has a `coach` | `StaffMember#coach_only_for_coach_role` |

Enforced in **services** (because they span records or read configuration):

| Rule | Where |
|---|---|
| Bookings never exceed session capacity | `Bookings::Create` (transactional, `SELECT … FOR UPDATE` on the session) |
| The contract covers the session's activity | `Bookings::Create` |
| The contract period is active and has balance | `Bookings::Create` |
| Cancellation respects `settings.booking.cancellation_hours` | `Bookings::Cancel` |
| Members may only self-book when `online_booking` is on | `Bookings::Create` |
| Cancelling frees a waitlist seat | `Bookings::Cancel` |

## 5. How the four example businesses configure

| | Boxing club | Pilates studio | EMS studio | Gym |
|---|---|---|---|---|
| Activity format | `collective` | `collective` | `individual` | `collective` |
| Capacity | 20 | 10 | 1 | high |
| Spaces | off | **on** (2 studios) | **on** (rooms) | off |
| ContractType | monthly, `unlimited_bookings` | 8 sessions, `session_count: 8` | 10 sessions | monthly, unlimited |
| `booking.online_booking` | true | true | true | false |
| `cancellation_hours` | 2 | 12 | 24 | n/a |
| Coach on session | optional | required | required | optional |

No new table, no new branch in the code, no `company.type` anywhere.
