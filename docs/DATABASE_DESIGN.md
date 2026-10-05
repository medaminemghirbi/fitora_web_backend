# Fitora — Database Design

PostgreSQL. UUID primary keys (`gen_random_uuid()`) throughout. Extensions:
`pgcrypto`, `pg_trgm` (trigram search), `btree_gist` (exclusion constraints).

Only **changes** from the current schema are specified here; every table not
mentioned keeps its present shape. The current shape is catalogued in
`CURRENT_ARCHITECTURE.md` §2.

## 1. New tables

### `spaces`

```ruby
create_table :spaces, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
  t.references :company, type: :uuid, null: false, foreign_key: true
  t.string  :name,     null: false
  t.string  :kind                                # free text: "studio", "ring", "room"
  t.integer :capacity                            # nil = unconstrained
  t.boolean :active,   null: false, default: true
  t.jsonb   :settings, null: false, default: {}
  t.timestamps
end
add_index :spaces, %i[company_id name], unique: true
add_index :spaces, :name, using: :gin, opclass: :gin_trgm_ops
add_check_constraint :spaces, "capacity IS NULL OR capacity > 0", name: "spaces_capacity_positive"
```

`kind` is free text on purpose. A fixed enum of room types is exactly the
hardcoding the brief forbids, and nothing branches on it.

### `activity_spaces`

```ruby
create_table :activity_spaces, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
  t.references :activity, type: :uuid, null: false, foreign_key: true
  t.references :space,    type: :uuid, null: false, foreign_key: true
  t.timestamps
end
add_index :activity_spaces, %i[activity_id space_id], unique: true
```

Empty set = the activity may run anywhere. This keeps the common case
(one room, or no constraint) free of rows.

## 2. Altered tables

### `companies`

```ruby
add_column    :companies, :settings, :jsonb, null: false, default: {}
add_index     :companies, :settings, using: :gin

remove_column :companies, :locations_count          # counter for a deleted table
remove_column :companies, :business_hours_start     # → settings.hours.start
remove_column :companies, :business_hours_end       # → settings.hours.end
remove_column :companies, :working_days             # → settings.hours.working_days
remove_column :companies, :primary_color            # → settings.branding.primary_color
```

Each removal is preceded by a backfill into `settings` in the same migration,
and each is individually reversible (`up`/`down` written by hand, not
`change`). See `MIGRATION_PLAN.md` §3.

The GIN index on `settings` exists for platform-superadmin queries like "which
companies have online booking on" — not for hot-path reads, which always
load the whole company row anyway.

### `sessions`

```ruby
add_reference :sessions, :space, type: :uuid, null: true, foreign_key: true

add_exclusion_constraint :sessions,
  "space_id WITH =, tsrange(starts_at, ends_at) WITH &&",
  where: "status = 0 AND space_id IS NOT NULL",
  using: :gist,
  name: "no_overlapping_space_sessions"
```

Mirrors `no_overlapping_coach_sessions` exactly, including the
scheduled-only (`status = 0`) predicate — a cancelled session must not block
its room.

### `contracts`

```ruby
change_column_null :contracts, :activity_id, true
```

NULL now carries meaning: "every activity this contract's `ContractType`
covers". No data changes; every existing row stays valid.

### `bookings`

```ruby
add_column :bookings, :waitlist_position, :integer, null: true
add_index  :bookings, %i[session_id waitlist_position],
           where: "status = 4", name: "index_bookings_waitlist_order"
add_check_constraint :bookings,
  "(status = 4) = (waitlist_position IS NOT NULL)",
  name: "waitlist_position_iff_waitlisted"
```

Status `4` = `waitlisted`. (Not 3 — `bookings.status` already uses 0..3 for
`confirmed`, `cancelled`, `completed`, `no_show`, so the queue takes the next
value rather than renumbering an enum written into every existing row.) The check constraint makes the two facts
inseparable, so a waitlisted booking can never be position-less and a
confirmed one can never carry a stale position.

### `staff_members`

```ruby
change_column_null :staff_members, :role_id, false   # after backfill
remove_column      :staff_members, :role             # the integer enum
```

The `before_validation :sync_assigned_role_from_enum` hook and
`StaffMember::ROLES`/`CAPABILITIES` constants are deleted with it.

## 3. Dropped tables

None.

**`platform_settings` is KEPT.** An earlier draft of this document proposed
folding it into an ENV-backed constant on the grounds that a single integer
does not need a table. That was wrong: `annual_discount_percent` is edited
at runtime by a platform superadmin through
`PATCH /api/v1/superadmin/subscription_pricing`. A constant would delete a working
feature. A single-row settings table is the right shape for an
superadmin-editable global, and it stays.

## 4. Indexing review

Carried forward unchanged: the trigram GIN indexes on names, emails and
phones (`clients`, `users`, `companies`, `activities`, `contract_types`) that
back the search-everywhere requirement; the partial unique index on held
bookings; the composite indexes on `(company_id, status, created_at)` for
payments and `(company_id, created_at)` for audit logs.

Added with the new tables: `spaces(company_id, name)` unique,
`spaces(name)` trigram, `activity_spaces(activity_id, space_id)` unique,
`bookings(session_id, waitlist_position)` partial.

Reviewed and deliberately **not** added: an index on `contracts.activity_id`
now that it is nullable — the column is read through an already-indexed
`contract_id`/`company_id` path, never filtered on alone.

## 5. Constraint inventory after the rewrite

| Constraint | Table | Kind |
|---|---|---|
| `no_overlapping_coach_sessions` | sessions | GiST exclusion |
| `no_overlapping_space_sessions` | sessions | GiST exclusion **(new)** |
| held booking uniqueness | bookings | partial unique index |
| `contracts_remaining_bookings_not_negative` | contracts | check |
| `waitlist_position_iff_waitlisted` | bookings | check **(new)** |
| `spaces_capacity_positive` | spaces | check **(new)** |
| membership uniqueness | memberships | unique index |
| one seat per user | staff_members | unique index |
| unique slug | companies | unique index |
| unique invoice number | invoices | unique index |
| unique role key per company | roles | unique index |
| case-insensitive unique client email | clients | unique functional index |

## 6. Rules for future schema work

1. A configuration value never becomes a column. A business entity never
   becomes JSON.
2. Every FK to a company-owned table gets a `company_id` on the child if the
   child is ever queried by tenant, even when it is reachable through a
   parent — the join cost is not worth an unscoped query.
3. Any rule that can be expressed as a database constraint is expressed as
   one. Application-level uniqueness is a race, not a rule.
4. Destructive migrations are written with explicit `up`/`down`, never
   `change`, and are preceded by a backfill in the same file.
