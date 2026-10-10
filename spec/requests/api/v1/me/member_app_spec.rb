require "rails_helper"

# A member's own app. The gym enabled their account; there is no directory,
# no self-signup and no way to reach a gym they have not joined.
RSpec.describe "Api::V1::Me", type: :request do
  let(:admin) { create(:user, :admin) }
  # The member app is a Pro feature — see "on a Starter account" below.
  let(:company) { create(:company, :pro, admin: admin) }
  let(:activity) { create(:activity, company: company) }
  let(:member) do
    create(:client, company: company, email: "member@example.test", password: "password123")
  end

  # Booking needs a live subscription covering the activity — the member app
  # does not get to bypass what the desk is held to.
  def subscribe!(price: 240)
    plan = create(:contract_type, company: company, name: "3 mois")
    create(:contract_type_activity, contract_type: plan, activity: activity, price: price)
    create(:contract, client: member, company: company, contract_type: plan, activity: activity)
  end

  # Every leaf value in a nested payload, for asserting that a figure is
  # nowhere in it regardless of which key it might have hidden behind.
  def deep_values(node)
    case node
    when Hash then node.values.flat_map { |v| deep_values(v) }
    when Array then node.flat_map { |v| deep_values(v) }
    else [ node ]
    end
  end

  def session_at(time, **attrs)
    create(:session, company: company, activity: activity,
                     starts_at: time, ends_at: time + 1.hour, **attrs)
  end

  describe "GET /api/v1/me/sessions" do
    it "lists the gym's upcoming sessions" do
      soon = session_at(2.days.from_now)
      session_at(2.days.ago)

      get "/api/v1/me/sessions", headers: auth_headers(member)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["sessions"].map { |s| s["id"] }).to eq([ soon.id ])
    end

    it "says how much room is left, never how many people are in it, nor the price" do
      session_at(2.days.from_now, capacity: 10)

      get "/api/v1/me/sessions", headers: auth_headers(member)

      body = response.parsed_body["sessions"].first
      expect(body["spots_left"]).to eq(10)
      expect(body.keys).not_to include("confirmed_count", "price")
    end

    it "marks the sessions this member already holds a place in" do
      booked = session_at(2.days.from_now)
      create(:booking, session: booked, client: member, status: :confirmed)
      session_at(3.days.from_now)

      get "/api/v1/me/sessions", headers: auth_headers(member)

      by_id = response.parsed_body["sessions"].index_by { |s| s["id"] }
      expect(by_id[booked.id]["already_booked"]).to be true
      expect(by_id.values.count { |s| s["already_booked"] }).to eq(1)
    end

    it "never shows another gym's schedule" do
      elsewhere = create(:company)
      create(:session, company: elsewhere, activity: create(:activity, company: elsewhere),
                       starts_at: 2.days.from_now, ends_at: 2.days.from_now + 1.hour)

      get "/api/v1/me/sessions", headers: auth_headers(member)

      expect(response.parsed_body["sessions"]).to be_empty
    end

    it "404s on a gym the member has not joined, rather than admitting it exists" do
      get "/api/v1/me/sessions", params: { company_id: create(:company).id }, headers: auth_headers(member)

      expect(response).to have_http_status(:not_found)
    end

    it "is closed to a staff login — this is the member's half" do
      get "/api/v1/me/sessions", headers: auth_headers(admin)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/me/bookings" do
    it "books a place at the member's own gym" do
      subscribe!
      upcoming = session_at(2.days.from_now)

      post "/api/v1/me/bookings", params: { session_id: upcoming.id }, headers: auth_headers(member)

      expect(response).to have_http_status(:created)
      expect(member.bookings.count).to eq(1)
    end

    it "refuses a member with no live subscription — the app bypasses nothing the desk is held to" do
      upcoming = session_at(2.days.from_now)

      expect {
        post "/api/v1/me/bookings", params: { session_id: upcoming.id }, headers: auth_headers(member)
      }.not_to change(Booking, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses a session that is already full" do
      subscribe!
      full = session_at(2.days.from_now, capacity: 1)
      create(:booking, session: full, client: create(:client, company: company), status: :confirmed)

      post "/api/v1/me/bookings", params: { session_id: full.id }, headers: auth_headers(member)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses a session at a gym the member has not joined" do
      elsewhere = create(:company)
      theirs = create(:session, company: elsewhere, activity: create(:activity, company: elsewhere),
                                starts_at: 2.days.from_now, ends_at: 2.days.from_now + 1.hour)

      expect {
        post "/api/v1/me/bookings", params: { session_id: theirs.id }, headers: auth_headers(member)
      }.not_to change(Booking, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/me/bookings/:id/cancel" do
    it "cancels the member's own booking" do
      booking = create(:booking, session: session_at(2.days.from_now), client: member, status: :confirmed)

      post "/api/v1/me/bookings/#{booking.id}/cancel", headers: auth_headers(member)

      expect(response).to have_http_status(:ok)
      expect(booking.reload.status).to eq("cancelled")
    end

    it "cannot reach somebody else's booking" do
      other = create(:booking, session: session_at(2.days.from_now),
                               client: create(:client, company: company), status: :confirmed)

      post "/api/v1/me/bookings/#{other.id}/cancel", headers: auth_headers(member)

      expect(response).to have_http_status(:not_found)
      expect(other.reload.status).to eq("confirmed")
    end
  end

  describe "GET /api/v1/me/profile" do
    it "returns the subscription they train on, without a single figure in money" do
      subscribe!

      get "/api/v1/me/profile", headers: auth_headers(member)

      expect(response).to have_http_status(:ok)
      subscription = response.parsed_body["subscription"]
      expect(subscription["plan_name"]).to eq("3 mois")
      expect(subscription["activity_name"]).to eq(activity.name)
      expect(subscription.keys).not_to include("final_price", "base_price", "amount_due", "payment_status", "discount")
      # Not a substring search on the raw body: "240" turns up inside a
      # random UUID often enough to fail a green build. Check the values
      # themselves, which is what the rule is actually about.
      expect(deep_values(response.parsed_body)).not_to include(240, 240.0, "240", "240.0")
    end

    it "returns their attendance, and nobody else's" do
      mine = create(:booking, session: session_at(2.days.ago), client: member, status: :confirmed)
      create(:attendance_record, booking: mine, status: :present)
      theirs = create(:booking, session: session_at(3.days.ago),
                                client: create(:client, company: company), status: :confirmed)
      create(:attendance_record, booking: theirs, status: :present)

      get "/api/v1/me/profile", headers: auth_headers(member)

      attendance = response.parsed_body["attendance"]
      expect(attendance["rate"]).to eq(100)
      expect(attendance["recent"].map { |r| r["id"] }).to eq([ mine.id ])
    end

    it "says so plainly when there is no subscription" do
      get "/api/v1/me/profile", headers: auth_headers(member)

      expect(response.parsed_body["subscription"]).to be_nil
    end
  end

  describe "a member whose gym never enabled their account" do
    it "cannot sign in at all" do
      create(:client, company: company, email: "quiet@example.test")

      post "/api/v1/auth/login", params: { email: "quiet@example.test", password: "password123" }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "on a Starter account" do
    let(:starter) { create(:company) }
    let(:starter_member) { create(:client, company: starter, email: "starter@example.test", password: "password123") }

    before { create(:subscription, company: starter) }

    it "refuses the member's sign-in: the member app comes with Pro" do
      post "/api/v1/auth/login", params: { email: starter_member.email, password: "password123" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("member_app_not_included")
    end

    it "refuses a token already issued" do
      get "/api/v1/me/sessions", headers: auth_headers(starter_member)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("member_app_not_included")
    end

    it "keeps the app closed while the account is on its free trial: the app is Pro's" do
      create(:invoice, :trial, company: starter)

      post "/api/v1/auth/login", params: { email: starter_member.email, password: "password123" }

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("member_app_not_included")
    end

    it "shows a member of a Pro gym and a Starter gym only the Pro one" do
      member.join!(starter)

      get "/api/v1/me/profile", headers: auth_headers(member)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["gyms"].map { |g| g["id"] }).to eq([ company.id ])
    end
  end
end
