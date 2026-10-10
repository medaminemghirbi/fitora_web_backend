require "rails_helper"

RSpec.describe "Api::V1::Coaches", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin) }

  describe "GET /api/v1/coaches" do
    it "lets a moderator read the roster (to assign a coach to a session)" do
      create(:coach, company: company)
      moderator = create(:staff_member, company: company, role: :moderator)

      get "/api/v1/coaches", headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["coaches"].size).to eq(1)
    end

    it "lets a moderator add a coach — managing coaches is theirs" do
      moderator = create(:staff_member, company: company, role: :moderator)

      post "/api/v1/coaches", params: { coach: { first_name: "New", last_name: "Coach" } }, headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:created)
    end

    it "forbids a coach from adding one" do
      coach_login = create(:staff_member, company: company, role: :coach)

      post "/api/v1/coaches", params: { coach: { first_name: "New", last_name: "Coach" } }, headers: auth_headers(coach_login.user)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/coaches/:id/login" do
    it "provisions a fresh login for a coach who has none yet" do
      coach = create(:coach, company: company)

      post "/api/v1/coaches/#{coach.id}/login", params: { email: "coach@example.com", password: "password123" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["coach"]
      expect(body["has_login"]).to be true
      # Masked in the response (EmailMask); the account itself has the whole address.
      expect(body["login_email"]).to eq("co****ch@example.com")
      expect(coach.reload.staff_member.user.email).to eq("coach@example.com")

      post "/api/v1/auth/login", params: { email: "coach@example.com", password: "password123" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["account_type"]).to eq("user")
    end

    it "resets an existing coach login rather than creating a duplicate account" do
      coach = create(:coach, company: company)
      post "/api/v1/coaches/#{coach.id}/login", params: { email: "coach2@example.com", password: "password123" }, headers: auth_headers(admin)
      first_staff_member_id = coach.reload.staff_member.id

      post "/api/v1/coaches/#{coach.id}/login", params: { email: "coach2-new@example.com", password: "newpassword123" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(coach.reload.staff_member.id).to eq(first_staff_member_id)
      expect(coach.staff_member.user.reload.email).to eq("coach2-new@example.com")
    end

    it "forbids a coach — another coach's login is not theirs to set" do
      coach_login = create(:staff_member, company: company, role: :coach)
      coach = create(:coach, company: company)

      post "/api/v1/coaches/#{coach.id}/login", params: { email: "coach3@example.com", password: "password123" }, headers: auth_headers(coach_login.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "lets a staff member whose role grants :coaches set a login" do
      staff = create(:staff_member, company: company, role: :moderator,
                     assigned_role: create(:role, company: company, permissions: %w[coaches]))
      coach = create(:coach, company: company)

      post "/api/v1/coaches/#{coach.id}/login", params: { email: "coach3@example.com", password: "password123" }, headers: auth_headers(staff.user)

      expect(response).to have_http_status(:ok)
    end

    it "forbids a coach from setting another coach's login" do
      coach_staff = create(:staff_member, company: company, role: :coach)
      other_coach = create(:coach, company: company)

      post "/api/v1/coaches/#{other_coach.id}/login", params: { email: "x@example.com", password: "password123" }, headers: auth_headers(coach_staff.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "404s for a coach belonging to another company" do
      other_coach = create(:coach)

      post "/api/v1/coaches/#{other_coach.id}/login", params: { email: "x@example.com", password: "password123" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "rejects a duplicate email already used by another account" do
      create(:user, email: "taken@example.com")
      coach = create(:coach, company: company)

      post "/api/v1/coaches/#{coach.id}/login", params: { email: "taken@example.com", password: "password123" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
