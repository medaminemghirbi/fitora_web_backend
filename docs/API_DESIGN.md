# Fitora — API Design

`/api/v1`, JSON, JWT bearer auth. One version; the rewrite happens inside it
rather than behind a `/v2`, because there is exactly one client and shipping
two live surfaces would double the security review.

## 1. Namespaces map to audiences

| Namespace | Audience | Principal |
|---|---|---|
| `/api/v1/*` (root) | staff-side operations | `User` (admin or staff) |
| `/api/v1/admin/*` | admin-privileged reads (revenue, exports) | `User#admin?` or `revenue` capability |
| `/api/v1/coach/*` | a coach's own day **(new)** | staff on the coach role |
| `/api/v1/me/*` | the member's own app | `Client` |
| `/api/v1/superadmin/*` | the SaaS itself | `User#superadmin?`, no tenant |

This is the audit unit: to review what a coach can reach, read one directory.

## 2. Conventions

- **Plural resource nouns**, standard verbs. Non-CRUD transitions are named
  member actions (`POST /bookings/:id/cancel`), not magic `PATCH` payloads.
- **IDs in the path are always scoped**: `GET /clients/:id` resolves through
  the caller's company. A foreign id yields **404**.
- **No `company_id` in any request** from a staff or member client. It is
  derived. The single exception is `/me/*`, where `?company_id=` selects
  among the member's *own* memberships and is validated against them.
- **Lists** accept `?page`, `?per_page` (max 100), `?q` (trigram search),
  and resource-specific filters. They return
  `{ data: [...], meta: { page, per_page, total, total_pages } }`.
- **Errors** are `{ error: "message", errors: ["…"] }` with the status
  carrying the meaning:

| Status | Meaning |
|---|---|
| 401 | no/invalid token |
| 402 | company locked (trial expired / suspended) |
| 403 | authenticated, lacks the capability |
| 404 | not found **or** not yours |
| 422 | validation failed |
| 429 | rate limited |

- **Serializers, always.** No controller renders a model directly. A
  serializer never queries; controllers preload.
- **Timestamps** are ISO-8601 UTC. The company's timezone is metadata the
  client formats with, never a server-side formatting concern.
- **Money** is sent as a decimal string plus an explicit `currency`, never a
  float.

## 3. Endpoint surface

### Root (staff)

```
GET    /bootstrap                     whole post-login context in one call
GET    /app_version

resource  /company                    show, update            (settings live here)
resources /companies                  index, create; POST :id/switch
GET    /branding

resources /activities                 full CRUD
resources /spaces                     full CRUD               (new)
resources /coaches                    full CRUD; POST :id/login
resources /staff                      index, show, create, update
resources /roles                      index, create, update, destroy

resources /sessions                   index, show, create, update
  POST   /sessions/:id/cancel
  GET    /sessions/schedule_pdf
resources /recurring_schedules        index, create, update

resources /clients                    index, show, create, update
resources /contract_types             index, show, create, update
resources /contracts                  index, show, create, update, destroy
  POST   /contracts/:id/renew
  POST   /contracts/:id/cancel
  GET    /contracts/:id/receipt
resources /payments                   index, show, create; POST :id/refund
resources /bookings                   index, show, create
  POST   /bookings/:id/cancel
  POST   /bookings/:id/remind
resources /attendance                 index, create

resources /notifications              index, show; PATCH :id/read; POST read_all; GET unread_count
resources /audit_logs                 index
resources /support_tickets            index, create; GET :id/attachments/:attachment_id
resources /invoices                   index, show (PDF)
GET    /subscription
POST   /onboarding/dismiss            → replaced, see §4
data_exchange/:entity/{template,export,import}
```

### `/admin`

```
GET /admin/dashboard
GET /admin/revenue
GET /admin/reports/export
```

### `/coach`

```
GET /coach/members           members across the coach's own sessions
```

**One endpoint, not a namespace.** An earlier draft of this document proposed
`/coach/today`, `/coach/sessions`, `/coach/sessions/:id` and
`/coach/sessions/:id/attendance`. All of those already exist and already
narrow to the coach's own sessions — `SessionsController#base_scope` and
`AttendanceController#accessible_sessions` both filter on
`current_staff_member.coach_id`. Duplicating them here would give that
narrowing a second implementation and a second chance to be wrong.

So the namespace holds only what nothing else answers: who this coach trains.
It is scoped to `current_staff_member.coach_id`; a coach cannot pass a
`coach_id`. It returns no money and no subscription detail — a coach has no
business with either.

### `/me` (member)

```
GET    /me/profile
GET    /me/sessions                bookable schedule (respects online_booking + booking_opens_days)
resources /me/bookings             index, create; POST :id/cancel
GET    /me/notifications                                                              (new)
```

`/me/contracts`, `/me/attendance` and `/me/companies` were proposed here and
are **withdrawn**: `GET /me/profile` already returns the subscription with
`remaining_bookings`, the attendance rate with recent history, and the gyms
this person belongs to. Three endpoints for data one already carries would be
three more things to keep scoped correctly.

```
```

### `/superadmin`

```
resources /superadmin/companies         index, show
  PATCH  :id/subscription | :id/settings | :id/company_limit
  POST   :id/impersonate
  GET    :id/invoices | POST :id/invoices | DELETE :id/invoices/:invoice_id
GET/PATCH /superadmin/subscription_pricing
resources /superadmin/app_updates       index, create
resources /superadmin/support_tickets   index; PATCH :id/resolve; GET :id/attachments/:id
GET  /superadmin/metrics                platform KPIs                                      (new)
```

## 4. Onboarding

The dismissible checklist is replaced by a resumable, server-tracked flow.
State lives in `companies.settings.onboarding` (`{ step:, completed: [] }`)
so a half-finished setup survives a logout.

```
GET   /onboarding            current step, what is done, what remains
PATCH /onboarding            advance/complete a step
POST  /onboarding/skip       skip an optional step (spaces, staff)
POST  /onboarding/dismiss    leave the flow; reachable again from settings
```

Steps: `company → activities → spaces (skippable) → plans → staff (skippable)
→ done`. No step forces configuration the business does not need — a gym with
one room and no staff reaches `done` in three screens.

## 5. Cross-cutting

- **Rate limiting** via Rack::Attack on `auth/login` (by IP and by email),
  `password_resets#create`, `email_verifications#create`, and a global
  per-token ceiling. Currently absent — added in Phase 4.
- **Audit logging** on every write to money, membership, roles, staff,
  settings, and on every impersonated request.
- **Pagination is mandatory** on every index. An unpaginated list endpoint is
  a review failure.
- **No endpoint returns a raw model attribute set.** Sensitive fields
  (`password_digest`, `*_token_digest`, `token_version`) are absent from every
  serializer by construction, not by omission.
