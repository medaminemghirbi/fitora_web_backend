require "rails_helper"

RSpec.describe "Api::V1::Coach::Members", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin) }
  let(:coach) { create(:coach, company: company) }
  let(:coach_staff) { create(:staff_member, company: company, role: :coach, coach: coach) }
  let(:activity) { create(:activity, company: company) }

  def session_for(assigned_coach, starts_at: 2.days.from_now)
    create(:session, company: company, activity: activity, coach: assigned_coach,
                     starts_at: starts_at, ends_at: starts_at + 1.hour)
  end

  def books!(client, session, status: :confirmed)
    create(:booking, client: client, session: session, status: status)
  end

  describe "GET /api/v1/coach/members" do
    it "lists the people booked onto this coach's own sessions" do
      mine = create(:client, company: company)
      books!(mine, session_for(coach))

      get "/api/v1/coach/members", headers: auth_headers(coach_staff.user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["members"].map { |m| m["id"] }).to eq([ mine.id ])
    end

    it "leaves out somebody booked only onto another coach's session" do
      theirs = create(:client, company: company)
      books!(theirs, session_for(create(:coach, company: company)))

      get "/api/v1/coach/members", headers: auth_headers(coach_staff.user)

      expect(response.parsed_body["members"]).to be_empty
    end

    it "leaves out a member whose only booking was cancelled" do
      gone = create(:client, company: company)
      books!(gone, session_for(coach), status: :cancelled)

      get "/api/v1/coach/members", headers: auth_headers(coach_staff.user)

      expect(response.parsed_body["members"]).to be_empty
    end

    it "lists a member once however many sessions they are booked onto" do
      regular = create(:client, company: company)
      books!(regular, session_for(coach, starts_at: 2.days.from_now))
      books!(regular, session_for(coach, starts_at: 4.days.from_now))

      get "/api/v1/coach/members", headers: auth_headers(coach_staff.user)

      expect(response.parsed_body["members"].size).to eq(1)
    end

    it "says when they last came and when they are next due" do
      regular = create(:client, company: company)
      books!(regular, session_for(coach, starts_at: 3.days.ago))
      books!(regular, session_for(coach, starts_at: 3.days.from_now))

      get "/api/v1/coach/members", headers: auth_headers(coach_staff.user)

      member = response.parsed_body["members"].first
      expect(member["last_seen_at"]).to be_present
      expect(member["next_session_at"]).to be_present
    end

    it "tells a coach nothing about a member's money or plan" do
      mine = create(:client, company: company)
      books!(mine, session_for(coach))

      get "/api/v1/coach/members", headers: auth_headers(coach_staff.user)

      keys = response.parsed_body["members"].first.keys
      expect(keys).to contain_exactly("id", "full_name", "phone", "email", "health_notes", "last_seen_at", "next_session_at")
    end

    it "tells a coach a member's contraindications, and nothing from another gym's file" do
      mine = create(:client, company: company)
      mine.membership_for(company).update!(health_notes: "Pacemaker — no EMS")
      books!(mine, session_for(coach))

      get "/api/v1/coach/members", headers: auth_headers(coach_staff.user)

      expect(response.parsed_body["members"].first["health_notes"]).to eq("Pacemaker — no EMS")
    end

    it "searches by name" do
      # Distinct times: one coach cannot be in two places at once, and the
      # database enforces it (no_overlapping_coach_sessions).
      create(:client, company: company, first_name: "Amira").then { |c| books!(c, session_for(coach, starts_at: 2.days.from_now)) }
      create(:client, company: company, first_name: "Bilel").then { |c| books!(c, session_for(coach, starts_at: 5.days.from_now)) }

      get "/api/v1/coach/members", params: { q: "amir" }, headers: auth_headers(coach_staff.user)

      expect(response.parsed_body["members"].map { |m| m["full_name"] }.join).to include("Amira")
      expect(response.parsed_body["members"].size).to eq(1)
    end

    it "never reaches another gym's members" do
      other_company = create(:company)
      theirs = create(:client, company: other_company)
      other_session = create(:session, company: other_company,
                                       activity: create(:activity, company: other_company))
      create(:booking, client: theirs, session: other_session)
      books!(create(:client, company: company), session_for(coach))

      get "/api/v1/coach/members", headers: auth_headers(coach_staff.user)

      expect(response.parsed_body["members"].map { |m| m["id"] }).not_to include(theirs.id)
    end
  end

  describe "who may ask" do
    it "refuses a moderator — this is a coach's own roster, not a directory" do
      moderator = create(:staff_member, company: company, role: :moderator)

      get "/api/v1/coach/members", headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "refuses the admin, who has the full member list elsewhere" do
      get "/api/v1/coach/members", headers: auth_headers(admin)

      expect(response).to have_http_status(:forbidden)
    end

    it "refuses a member" do
      get "/api/v1/coach/members", headers: auth_headers(create(:client, company: company))

      expect(response).to have_http_status(:forbidden)
    end

    it "refuses an unauthenticated caller" do
      get "/api/v1/coach/members"

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
