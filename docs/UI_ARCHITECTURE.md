# Fitora — UI Architecture

Angular, standalone components, signals. Full redesign of every screen across
five shells.

## 1. What the redesign keeps and what it replaces

The token layer in `src/styles/_tokens.scss` is **the foundation, not a
casualty**. It already does the right thing: one source of truth for colour,
spacing, elevation, radius and motion; a light palette on `:root`; a dark
palette redefined under both `prefers-color-scheme` and `[data-theme="dark"]`
so the in-app toggle wins in both directions. The redesign extends it — it
does not restart it.

What the redesign does replace:

| Item | Problem | Action |
|---|---|---|
| `_adminlte.scss` (401 lines) | A superadmin-template skin. The product should not look like SuperadminLTE. | Delete; fold anything still needed into component styles. |
| `_fitora.scss` (1208 lines) | A global stylesheet doing component work, which is why screens drift. | **Phase 7, not Phase 5.** It is mostly a Bootstrap *override* layer — `.btn`, `.form-control`, `.table`, `.alert`, `.badge` restyled with tokens — and those classes appear across 49 templates. It cannot shrink until the templates stop using them, which is the redesign itself. The "under 250 lines" target holds only *after* that. |
| `_bootstrap-vars.scss` | Bootstrap coupling on a design system that no longer needs it. | **Done (Phase 7).** Bootstrap removed entirely: its utilities reproduced in `styles/_utilities.scss` against Fitora's tokens, its five unthemed components in `styles/_leftovers.scss`. Stylesheet 420 kB → 171 kB. `scripts/check-css.mjs` fails the build on any class a template uses with no rule behind it. |
| Bootstrap Icons (`bi-*`) in nav blueprints | Icon set chosen by the template, not the brand. | One icon decision, applied everywhere, made before any screen work starts. |

## 2. Directory structure

```
src/app/
  core/
    auth/           AuthService, account recovery
    guards/         auth, guest, role, staffRole, capability, company, member, settings
    interceptors/   jwt, error, loading
    models/         one typed model per API resource
    services/       one service per API resource — no business logic
    configuration/  navigation blueprints, ConfigurationService, access directives
  shared/
    ui/             design-system primitives (no domain knowledge)
    components/     composed, still domain-free
    pipes/ utils/
  layout/
    superadmin-shell/  admin-shell/  desk-shell/  coach-shell/  member-shell/
  features/
    landing/ auth/
    superadmin/        companies, company-detail, metrics, pricing, support, updates
    admin/        dashboard, clients, calendar, sessions, bookings, contracts,
                  plans, activities, spaces, payments, revenue, team, roles,
                  settings, subscription, onboarding, notifications
    desk/         dashboard, search, check-in, quick-book, quick-sell   (new)
    coach/        today, schedule, session-detail, attendance, members  (new)
    member/       home, book, schedule, subscription, profile
```

Rules: a feature folder owns its components, and imports **downward only**
(`features → shared → core`). A feature never imports from another feature; a
shared component never knows a domain type. Any component over ~250 lines of
template or ~200 of class is split.

## 3. Five shells

| Shell | Route | Layout | Density | Primary device |
|---|---|---|---|---|
| Superadmin | `/superadmin` | dark aubergine rail, data-first | high | desktop |
| Admin | `/admin` | top navbar + contextual left rail, ⌘K palette | medium | desktop, responsive |
| Desk | `/desk` | **single-column, search-first, oversized touch targets** | low | tablet + desktop |
| Coach | `/coach` | day-centric, list-first | low | mobile-first |
| Member | `/member` | bottom tab bar, card-first | low | mobile-first |

### Desk (moderator) — new
The screen answers one question: *who is in front of me and what do they
need?* A persistent search field owns the top of every page; typing a name
resolves to a member card carrying their subscription state, today's booking,
and three actions — **check in**, **book**, **take payment**. No catalogues,
no settings, no revenue. Optimised for one-handed use on a counter tablet.

### Coach — rebuilt from one page to five
`Today` leads with the **next session** and a single action (take attendance).
Then the rest of the day, the week's schedule, per-session rosters, and the
members the coach actually trains. No money anywhere in the shell — not
hidden, absent.

### Member — rebuilt
Adds what the portal lacks today: active subscription with **remaining
sessions as the headline number**, booking history, attendance, notifications,
and gym switching for a person who belongs to more than one.

### Admin — rebuilt
Keeps the navbar + filter-rail + ⌘K direction, which is sound. The dashboard
stops being a wall of statistics and becomes **today's operations with the
exceptions surfaced**: expiring subscriptions, unpaid balances, sessions
without a coach, sessions over capacity.

## 4. Navigation

Driven by `NAV_BLUEPRINT` filtered at runtime by capability and `adminOnly` —
already the right mechanism, extended to five shells. Each shell declares its
own blueprint; no shell renders another's items. Adding a capability to a
role changes the menu with no code change.

| Shell | Items |
|---|---|
| Admin | Dashboard · Members · Schedule · Subscriptions (active / plans / activities / spaces) · Payments · Revenue · Team · Reports · Settings |
| Desk | Dashboard · Members · Check-in · Bookings · Schedule · Subscriptions |
| Coach | Today · Schedule · Members · Attendance · Profile |
| Member | Home · Book · My schedule · Subscription · Profile |
| Superadmin | Companies · Metrics · Pricing · Support · Updates |

## 5. Design system

Primitives live in `shared/ui`, consume tokens only, and know no domain type.
Existing and kept (rebuilt on the new language): `page-header`, `kpi-card`,
`drawer`, `form-modal`, `modal`, `skeleton`, `searchable-select`,
`filter-rail`, `status-filter`, `wizard-steps`, `action-menu`, `pagination`,
`empty-state`, `error-state`, `toast`, `confirm-dialog`, `avatar`,
`status-badge`, `spinner`, `checkin-panel`.

To add, **when a screen asks for one** — building a primitive with no
consumer is guessing at its shape:

- `data-table` (sorting, selection, responsive collapse, built-in empty and
  loading states) — Phase 7, with the list pages that will use it.
- `entity-card` — Phase 7. The desk and coach lists each wanted a different
  shape; generalising from two is premature.

Dropped as duplicates of what already exists: `stat-tile` (that is
`kpi-card`), `sheet` (that is `drawer`, which already traps focus — a bottom
placement is an input on it, not a new component), `segmented-control` (no
screen asks for one; `status-filter` covers the rail). `date-range-picker`
waits for a screen that needs it.

Non-negotiable per state:

- **Empty states** carry an explanation and the action that resolves them —
  never just "No data".
- **Loading** is a skeleton in the shape of the content, never a centred
  spinner on a full page.
- **Errors** state what failed and offer a retry.
- **Confirmation dialogs** only for destructive or irreversible actions.
  Cancelling a booking, yes. Saving a form, no.
- **Every list** has search, a total count, pagination, and `<mark class="fx-hl">`
  highlighting of the matched term — this is an existing, enforced convention.

## 6. Accessibility and interaction

Every form control has a label. Focus is visible and never removed. Modals
trap focus and close on Escape. Colour is never the only carrier of meaning
(status badges carry text). Contrast meets WCAG AA in both themes — the token
palette is validated, not assumed. The admin and superadmin shells are fully
keyboard-operable, ⌘K included.

## 7. State and data

Signals for local and shared state; no external store. Services are thin HTTP
wrappers returning typed models. Business rules stay on the backend — the
frontend may *mirror* a rule to disable a button early (for example, hiding
"cancel" inside the cancellation window), and the backend rejects it anyway.

Route-level lazy loading everywhere (already the case). Each shell is a
separate bundle; a member never downloads the admin shell.

## 8. Testing

Every component keeps its co-located `.spec.ts` — the existing convention.
Beyond that, required coverage:

- every guard, including denial paths
- navigation filtering per role
- the booking flow, the subscription sale flow, the check-in flow
- form validation and error rendering
- that no shell renders another shell's navigation
