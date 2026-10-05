# Fitora — Permissions & Access Control

## 1. Three independent gates

Every request passes through gates that are **not** interchangeable and must
not be collapsed:

```
1. Authentication  — who is this?              (JWT → User XOR Client)
2. Tenancy         — whose data may they see?  (derived server-side, never from params)
3. Capability      — may they do this thing?   (Role permissions)
4. Commercial      — is the account open?      (trial/subscription lock, 402)
```

A feature flag in `company.settings` is **not** a gate. It changes what the
product offers; it never grants access. Turning a feature on must never widen
anyone's permissions.

## 2. Principals

| Principal | Token claim | Tenant | Notes |
|---|---|---|---|
| Superadmin | `user_id`, `User#superadmin?` | **none** | Operates Fitora, not a gym. Reaches company data only through explicit, audited impersonation. |
| Admin | `user_id`, `User#admin?` | `users.active_company_id` | The gym's admin. All capabilities inside their active company, unconditionally. The only one who creates staff logins, assigns roles and edits them. |
| Staff | `user_id`, `User#staff?` | `staff_members.company_id` | Capabilities come from the assigned `Role`. |
| Client | `client_id` | via `memberships` | Only `/api/v1/me/*`. |

A token carries `user_id` **or** `client_id`, never both.

## 3. Capability catalogue

Code-defined (`Permission::CATALOG`) — capabilities are a property of the
platform; the roles built from them are the per-company configurable part.

| Key | Grants |
|---|---|
| `clients` | Member records: list, view, create, edit |
| `activities` | The activity catalogue |
| `spaces` | The space catalogue **(new)** |
| `coaches` | Team management: coaches and staff seats |
| `sessions` | Creating and editing the schedule |
| `bookings` | Booking and cancelling on a member's behalf |
| `checkin` | Attendance / check-in |
| `contracts` | Selling, renewing and cancelling member subscriptions |
| `contract_types` | The plan catalogue and its prices |
| `payments` | Taking and refunding payments |
| `revenue` | Financial totals and revenue reporting |
| `reports` | Dashboard and operational reports |
| `settings` | Company configuration **(new)** |

Two deliberate splits:

- **`payments` vs `revenue`** — taking money at the desk is the moderator's
  job; knowing what the business earns is not.
- **`reports` vs `revenue`** — a dashboard of today's operations carries no
  money figures unless `revenue` is also held.
- **`settings`** is new and separates "runs the gym" from "changes how the
  gym's software behaves", so a moderator can do the first without the second.

## 4. Built-in roles

Seeded per company, renameable and re-permissionable (except `admin`),
deletable only if custom and unassigned.

| Role | `key` | Permissions |
|---|---|---|
| Administrateur | `admin` | all (implicit — never checked against the array) |
| Modérateur | `moderator` | `sessions bookings clients contracts payments checkin reports coaches` |
| Coach | `coach` | `checkin` (+ read of own schedule and own members, which is namespace-gated, not capability-gated) |

On screen: "Administrateur" and "Super admin". The code says `admin` for
the gym's admin and `superadmin` for Fitora's operator.

Custom roles are any subset of the catalogue.

A moderator manages members and coaches — including a coach's own login,
but only a login on the coach role (`CoachesController#set_login`): an admin
may link a coach to a higher login, and resetting that one would be a way up.

## 5. Enforcement

### Backend — the only place that counts

```ruby
class Api::V1::SpacesController < Api::V1::BaseController
  before_action :require_company!
  before_action -> { require_capability!(:spaces) }, only: %i[create update destroy]
  before_action -> { require_schedule_reference_read!(:spaces) }, only: %i[index show]

  def show
    space = find_in_company!(Space.all, params[:id])   # never Space.find
    render json: SpaceSerializer.new(space).as_json
  end
end
```

Rules:

1. Every action states its gate in a `before_action`. No gate = a review failure.
2. Every lookup of a company-owned record goes through `find_in_company!`.
3. Every lookup of a `Client` goes through `current_company.clients`.
4. Strong params never permit `company_id`, `role_id`, `active`,
   `password_digest`, or any `*_count` column.
5. Read access to reference data a schedule is built from (activities,
   spaces, hours) is granted to the owning capability **or** `sessions` —
   you cannot plan a week without seeing the options.

### A member's token never reaches a staff endpoint

`Api::V1::BaseController#reject_member_token!` refuses any request carrying
a `client_id` claim, with the member's own `Api::V1::Me::*` namespace as the
single exemption. A new staff controller is therefore closed to members by
default, rather than relying on `require_company!` happening to run first.

### Frontend — navigation only

Guards (`capabilityGuard`, `roleGuard`, `staffRoleGuard`) and
`NavigationService` filtering exist so the UI is not misleading. They are
**not** security, and no backend check may be omitted because a guard exists.

## 6. Platform superadmin isolation

`Api::V1::Superadmin::*` controllers have **no `current_company`**. A superadmin
reaching gym data does so only by impersonation:

- `POST /superadmin/companies/:id/impersonate` issues a token carrying both
  `user_id` (the admin) and `impersonator_id` (the superadmin).
- The start of the session is logged as `superadmin.impersonation_started`, and
  every audited action taken *during* it carries `impersonated_by_id` /
  `impersonated_by_email` in its metadata — stamped by `AuditLogs::Record`
  from `Current.impersonator`, so no call site has to remember to.
  (Before Phase 4 only the start was recorded, and `current_impersonator`
  was resolved on every request but read by nothing.)
- The frontend shows a persistent, unmissable impersonation banner.

A superadmin token alone reaches aggregate/company-metadata endpoints only —
never member records, bookings, or payments.

## 7. The tests that must exist

`spec/requests/security/` — one file per rule, each asserting a denial:

```
Admin of company A  → any company B resource        404 (not 403)
Moderator           → POST /staff, PATCH /staff/:id 403
Moderator           → POST/PATCH/DELETE /roles      403
Moderator           → PATCH /company (settings)     403
Moderator           → coach login on a higher role  403
Coach               → GET /admin/revenue            403
Coach               → GET /payments                 403
Coach               → PATCH /activities/:id         403
Client              → GET /clients                  403
Client              → GET /me/bookings?client_id=X  own data only, X ignored
Client              → another client's booking      404
Client              → /superadmin/*                      403
Staff               → /superadmin/*                      403
Superadmin               → GET /clients                  403 (no tenant)
Unauthenticated     → every endpoint                401
Locked company staff→ every operational endpoint    402
Mass assignment     → company_id / role_id in body  ignored, never applied
```

Cross-tenant reads return **404, not 403**: a 403 confirms the record exists.
