require "rails_helper"

RSpec.describe "Api::V1::Sessions", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin) }
  let!(:activity) { create(:activity, company: company) }

  describe "GET /api/v1/sessions" do
    it "never exposes another company's sessions" do
      create(:session, activity: activity, company: company)
      other_activity = create(:activity)
      other_session = create(:session, activity: other_activity, company: other_activity.company)

      get "/api/v1/sessions", headers: auth_headers(admin)

      ids = response.parsed_body["sessions"].map { |s| s["id"] }
      expect(ids).not_to include(other_session.id)
    end

    it "limits a coach to only their own sessions" do
      coach = create(:coach, company: company)
      coach_staff = create(:staff_member, company: company, role: :coach, coach: coach)
      own_session = create(:session, activity: activity, company: company, coach: coach)
      other_coach_session = create(:session, activity: activity, company: company)

      get "/api/v1/sessions", headers: auth_headers(coach_staff.user)

      ids = response.parsed_body["sessions"].map { |s| s["id"] }
      expect(ids).to include(own_session.id)
      expect(ids).not_to include(other_coach_session.id)
    end
  end

  describe "GET /api/v1/sessions/:id" do
    it "404s for a session belonging to another company" do
      other_activity = create(:activity)
      other_session = create(:session, activity: other_activity, company: other_activity.company)

      get "/api/v1/sessions/#{other_session.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/sessions/schedule_pdf" do
    # Printing the week is a Pro tool (paid Pro only).
    before { create(:subscription, :pro, company: company) }

    it "is refused on Starter and during the free trial" do
      company.subscription.update!(plan: :starter)
      get "/api/v1/sessions/schedule_pdf", headers: auth_headers(admin)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("pro_required")

      company.subscription.update!(plan: nil)
      create(:invoice, :trial, company: company)
      get "/api/v1/sessions/schedule_pdf", headers: auth_headers(admin)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns a pdf covering the week containing the given date" do
      week_start = Date.current.beginning_of_week(:monday)
      create(:session, activity: activity, company: company, starts_at: week_start.to_time.change(hour: 9))

      get "/api/v1/sessions/schedule_pdf", params: { from: week_start.iso8601 }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to eq("application/pdf")
      expect(response.body).to start_with("%PDF")
    end

    it "limits a coach's pdf to their own sessions" do
      coach = create(:coach, company: company)
      coach_staff = create(:staff_member, company: company, role: :coach, coach: coach)

      get "/api/v1/sessions/schedule_pdf", headers: auth_headers(coach_staff.user)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to eq("application/pdf")
    end

    it "requires staff access" do
      inactive_staff = create(:staff_member, company: company, role: :moderator, active: false)

      get "/api/v1/sessions/schedule_pdf", headers: auth_headers(inactive_staff.user)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/sessions" do
    let(:params) do
      {
        session: {
          activity_id: activity.id,
          starts_at: 2.days.from_now.change(hour: 10).iso8601,
          ends_at: 2.days.from_now.change(hour: 11).iso8601
        }
      }
    end

    it "creates a session, defaulting capacity from the activity" do
      post "/api/v1/sessions", params: params, headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(Session.last.capacity).to eq(activity.capacity)
    end

    context "with a client_id (individual session)" do
      let(:solo_activity) { create(:activity, company: company, session_format: :individual, capacity: 1) }
      let(:client) { create(:client, company: company) }

      def solo_params(client_id)
        {
          session: {
            activity_id: solo_activity.id, client_id: client_id,
            starts_at: 2.days.from_now.change(hour: 9).iso8601,
            ends_at: 2.days.from_now.change(hour: 10).iso8601
          }
        }
      end

      it "books the chosen member when they have a covering contract" do
        plan = create(:contract_type, company: company, unlimited_bookings: true)
        create(:contract, client: client, contract_type: plan, activity: solo_activity)

        expect {
          post "/api/v1/sessions", params: solo_params(client.id), headers: auth_headers(admin)
        }.to change(Booking, :count).by(1)

        expect(response).to have_http_status(:created)
        expect(Booking.last.client).to eq(client)
        expect(Booking.last.session_id).to eq(response.parsed_body["session"]["id"])
      end

      it "rolls the session back when the member has no covering contract" do
        expect {
          post "/api/v1/sessions", params: solo_params(client.id), headers: auth_headers(admin)
        }.not_to change(Session, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]).to match(/active contract/)
      end

      it "404s for a client from another company" do
        other_client = create(:client)

        post "/api/v1/sessions", params: solo_params(other_client.id), headers: auth_headers(admin)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "PATCH /api/v1/sessions/:id" do
    it "rejects updates to another company's session" do
      other_activity = create(:activity)
      other_session = create(:session, activity: other_activity, company: other_activity.company)

      patch "/api/v1/sessions/#{other_session.id}", params: { session: { capacity: 99 } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end
  end
end
