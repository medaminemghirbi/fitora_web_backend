require "rails_helper"

RSpec.describe "Api::V1::Bookings", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:company) { create(:company, admin: admin) }
  let(:activity) { create(:activity, company: company) }
  let(:session) { create(:session, activity: activity, company: company, capacity: 1) }
  let(:client) { create(:client, company: company) }
  # Booking is always settled against a contract — give the client a plan
  # that covers every activity in the company.
  let!(:client_plan) do
    create(:contract, client: client, contract_type: create(:contract_type, company: company, unlimited_bookings: true), activity: activity)
  end

  describe "POST /api/v1/bookings" do
    it "lets the admin book a client into a session" do
      post "/api/v1/bookings", params: { client_id: client.id, session_id: session.id }, headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["booking"]["status"]).to eq("confirmed")
      expect(response.parsed_body["booking"]["client"]["id"]).to eq(client.id)
    end

    it "lets a moderator (bookings capability) book a client" do
      moderator = create(:staff_member, company: company, role: :moderator)

      post "/api/v1/bookings", params: { client_id: client.id, session_id: session.id }, headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:created)
    end

    it "forbids a coach from booking a client (no bookings capability)" do
      coach = create(:staff_member, company: company, role: :coach)

      post "/api/v1/bookings", params: { client_id: client.id, session_id: session.id }, headers: auth_headers(coach.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "returns a friendly error when the session is full" do
      create(:booking, client: create(:client, company: company), session: session, status: :confirmed)

      post "/api/v1/bookings", params: { client_id: client.id, session_id: session.id }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("This session is full.")
    end
  end

  describe "POST /api/v1/bookings/:id/cancel" do
    it "lets the admin cancel a client's booking" do
      booking = create(:booking, client: client, session: session)

      post "/api/v1/bookings/#{booking.id}/cancel", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["booking"]["status"]).to eq("cancelled")
    end

    it "404s for another company's admin — set_booking is company-scoped, never reaches BookingPolicy" do
      other_admin = create(:user, :admin)
      create(:company, admin: other_admin)
      booking = create(:booking, client: client, session: session)

      post "/api/v1/bookings/#{booking.id}/cancel", headers: auth_headers(other_admin)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/bookings/:id" do
    it "returns the booking for the company that owns it" do
      booking = create(:booking, client: client, session: session)

      get "/api/v1/bookings/#{booking.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["booking"]["id"]).to eq(booking.id)
    end

    it "404s for another company entirely — set_booking is company-scoped" do
      other_admin = create(:user, :admin)
      create(:company, admin: other_admin)
      booking = create(:booking, client: client, session: session)

      get "/api/v1/bookings/#{booking.id}", headers: auth_headers(other_admin)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/bookings" do
    it "only returns the company's own bookings" do
      create(:booking, client: client, session: session)
      create(:booking, client: create(:client), session: create(:session, capacity: 5))

      get "/api/v1/bookings", headers: auth_headers(admin)

      body = response.parsed_body["bookings"]
      expect(body.size).to eq(1)
      expect(body.first["client"]["id"]).to eq(client.id)
    end

    it "narrows a coach (granted the bookings capability) to bookings on their own sessions" do
      coach_profile = create(:coach, company: company)
      bookings_role = create(:role, company: company, permissions: %w[bookings])
      coach_staff = create(:staff_member, company: company, role: :coach, coach: coach_profile, assigned_role: bookings_role)
      own_session = create(:session, activity: activity, company: company, coach: coach_profile)
      other_session = create(:session, activity: activity, company: company)
      create(:booking, client: client, session: own_session)
      create(:booking, client: client, session: other_session)

      get "/api/v1/bookings", headers: auth_headers(coach_staff.user)

      expect(response.parsed_body["bookings"].size).to eq(1)
    end

    it "forbids a coach with no bookings capability from browsing the booking list" do
      coach = create(:staff_member, company: company, role: :coach)

      get "/api/v1/bookings", headers: auth_headers(coach.user)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/bookings/:id/remind" do
    let(:booking) { create(:booking, client: client, session: session) }

    it "sends the reminder and returns sent" do
      allow(Sms::TunisieSmsClient).to receive(:send_message)

      post "/api/v1/bookings/#{booking.id}/remind", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("sent")
      expect(Sms::TunisieSmsClient).to have_received(:send_message).once
    end

    it "surfaces a gateway/config failure as a 422" do
      allow(Sms::TunisieSmsClient).to receive(:send_message)
        .and_raise(Sms::TunisieSmsClient::ConfigurationError, "TUNISIESMS_API_KEY is not set")

      post "/api/v1/bookings/#{booking.id}/remind", headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("TUNISIESMS_API_KEY is not set")
    end

    it "forbids a coach — coaches only have the checkin capability, never bookings" do
      coach_staff = create(:staff_member, company: company, role: :coach, coach: create(:coach, company: company))

      post "/api/v1/bookings/#{booking.id}/remind", headers: auth_headers(coach_staff.user)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "the list's filters and rail counts" do
    it "filters by status and reports how many each status holds" do
      confirmed = create(:booking, session: session, client: create(:client, company: company), status: :confirmed)
      create(:booking, session: session, client: create(:client, company: company), status: :cancelled)

      get "/api/v1/bookings", params: { status: "confirmed" }, headers: auth_headers(admin)

      expect(response.parsed_body["bookings"].map { |b| b["id"] }).to eq([ confirmed.id ])
      expect(response.parsed_body["counts"]["confirmed"]).to eq(1)
      expect(response.parsed_body["counts"]["cancelled"]).to eq(1)
      expect(response.parsed_body["counts"]["all"]).to eq(2)
    end

    it "filters by the session's day" do
      today = create(:booking, session: session, client: create(:client, company: company))
      other_session = create(:session, company: session.company, activity: session.activity,
                             starts_at: 10.days.from_now.change(hour: 9), ends_at: 10.days.from_now.change(hour: 10))
      create(:booking, session: other_session, client: create(:client, company: company))

      get "/api/v1/bookings", params: { date: session.starts_at.to_date.to_s }, headers: auth_headers(admin)

      expect(response.parsed_body["bookings"].map { |b| b["id"] }).to eq([ today.id ])
    end

    it "ignores an unparseable date rather than blowing up" do
      create(:booking, session: session, client: create(:client, company: company))

      get "/api/v1/bookings", params: { date: "pas-une-date" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["bookings"].size).to eq(1)
    end
  end
end
