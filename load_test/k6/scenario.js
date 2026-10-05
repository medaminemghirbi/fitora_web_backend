// Fitora load test — realistic mixed traffic against a locally-running
// Puma instance. Run `bin/rails load_test:seed` first (see load_test/README.md).
//
//   k6 run load_test/k6/scenario.js
//   k6 run -e BASE_URL=https://staging.fitora.io load_test/k6/scenario.js
//   k6 run -e MAX_MEMBER_VUS=2000 -e MAX_STAFF_VUS=100 load_test/k6/scenario.js
//
// Two scenarios run concurrently, weighted like real traffic: members
// (browsing/booking classes) vastly outnumber staff (dashboard/client
// list). Each iteration is one user session — login, then a couple of
// think-time-paced actions — not a tight request loop.
import http from "k6/http";
import { check, sleep, group } from "k6";
import { SharedArray } from "k6/data";
import { Counter } from "k6/metrics";

const accounts = JSON.parse(open("../data/accounts.json"));
const BASE_URL = __ENV.BASE_URL || accounts.base_url;
const PASSWORD = accounts.password;

const clients = new SharedArray("clients", () => accounts.clients);
const owners = new SharedArray("owners", () => accounts.owners);

const bookingConflicts = new Counter("booking_conflicts"); // expected under real contention — session full / already booked, not errors

// Staged ramps — MAX_*_VUS lets you push past what this box currently
// survives. Defaults are a sane local-box starting point, not "10,000":
// see load_test/README.md for what real 10K-concurrent capacity requires.
const maxMemberVUs = Number(__ENV.MAX_MEMBER_VUS || 300);
const maxStaffVUs = Number(__ENV.MAX_STAFF_VUS || 20);

export const options = {
  scenarios: {
    member_flow: {
      executor: "ramping-vus",
      exec: "memberFlow",
      startVUs: 0,
      stages: [
        { duration: "30s", target: Math.round(maxMemberVUs * 0.2) },
        { duration: "1m", target: Math.round(maxMemberVUs * 0.5) },
        { duration: "1m", target: maxMemberVUs },
        { duration: "1m", target: maxMemberVUs },
        { duration: "30s", target: 0 }
      ],
      gracefulRampDown: "10s"
    },
    staff_flow: {
      executor: "ramping-vus",
      exec: "staffFlow",
      startVUs: 0,
      stages: [
        { duration: "30s", target: Math.round(maxStaffVUs * 0.5) },
        { duration: "2m", target: maxStaffVUs },
        { duration: "30s", target: 0 }
      ],
      gracefulRampDown: "10s"
    }
  },
  thresholds: {
    http_req_failed: [ "rate<0.01" ],
    "http_req_duration{endpoint:login}": [ "p(95)<1000" ],
    "http_req_duration{endpoint:browse_sessions}": [ "p(95)<500" ],
    "http_req_duration{endpoint:create_booking}": [ "p(95)<800" ],
    "http_req_duration{endpoint:owner_dashboard}": [ "p(95)<500" ],
    "http_req_duration{endpoint:clients_list}": [ "p(95)<800" ]
  }
};

function login(email) {
  const res = http.post(
    `${BASE_URL}/api/v1/auth/login`,
    JSON.stringify({ email, password: PASSWORD }),
    { headers: { "Content-Type": "application/json" }, tags: { endpoint: "login" } }
  );
  check(res, { "login: 200": (r) => r.status === 200 });
  if (res.status !== 200) return null;
  return res.json("token");
}

function authed(token) {
  return { headers: { Authorization: `Bearer ${token}` } };
}

// One member session: log in, browse bookable classes, book one if
// available. Mirrors the client mobile app's "Réserver une séance" flow.
export function memberFlow() {
  const account = clients[Math.floor(Math.random() * clients.length)];
  const token = login(account.email);
  if (!token) return;
  sleep(Math.random() * 1.5 + 0.5); // think time after login

  group("browse and book a class", () => {
    const res = http.get(`${BASE_URL}/api/v1/me/sessions`, {
      ...authed(token),
      tags: { endpoint: "browse_sessions" }
    });
    const ok = check(res, { "sessions: 200": (r) => r.status === 200 });
    if (!ok) return;

    const sessions = res.json("sessions") || [];
    const bookable = sessions.filter((s) => s.availability === "available" && !s.already_booked);
    if (bookable.length === 0) return;

    sleep(Math.random() * 2 + 0.5); // think time while picking a class

    const target = bookable[Math.floor(Math.random() * bookable.length)];
    const bookRes = http.post(
      `${BASE_URL}/api/v1/me/bookings`,
      JSON.stringify({ session_id: target.id }),
      { ...authed(token), headers: { ...authed(token).headers, "Content-Type": "application/json" }, tags: { endpoint: "create_booking" } }
    );

    if (bookRes.status === 201) {
      check(bookRes, { "booking: confirmed": (r) => r.json("booking.status") !== undefined });
    } else {
      // A session filling up between browse and book, or a double-booking
      // attempt, is expected contention under real concurrency — not a
      // server error. Only 4xx/5xx outside that is a genuine failure.
      bookingConflicts.add(1);
      check(bookRes, { "booking: expected conflict, not a server error": (r) => r.status === 422 || r.status === 409 });
    }
  });

  sleep(Math.random() * 1 + 0.3);
}

// One staff/owner session: log in, check the dashboard, browse the client
// list — the "opening the app in the morning" flow.
export function staffFlow() {
  const account = owners[Math.floor(Math.random() * owners.length)];
  const token = login(account.email);
  if (!token) return;
  sleep(Math.random() * 1 + 0.3);

  group("owner dashboard + client list", () => {
    const dash = http.get(`${BASE_URL}/api/v1/owner/dashboard`, {
      ...authed(token),
      tags: { endpoint: "owner_dashboard" }
    });
    check(dash, { "dashboard: 200": (r) => r.status === 200 });

    sleep(Math.random() * 1.5 + 0.5);

    const list = http.get(`${BASE_URL}/api/v1/clients`, {
      ...authed(token),
      tags: { endpoint: "clients_list" }
    });
    check(list, { "clients: 200": (r) => r.status === 200 });
  });

  sleep(Math.random() * 2 + 0.5);
}
