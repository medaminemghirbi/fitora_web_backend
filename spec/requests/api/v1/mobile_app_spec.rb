require "rails_helper"

# Settings → Application mobile (a Pro tool) and the public key lookup the
# mobile app makes before anyone signs in (mobile/src/lib/tenant-config.ts).
RSpec.describe "Mobile app pairing", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, :pro, admin: admin, name: "Studio Lumen") }

  describe "GET /api/v1/mobile_app" do
    it "makes both keys on first use, with their QR codes, and keeps them" do
      get "/api/v1/mobile_app", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["member_code"]).to match(/\A[a-z2-9]{8}\z/)
      expect(body["coach_key"]).to match(/\A[a-z2-9]{12}\z/)
      expect(body["member_qr_svg"]).to include("<svg")

      get "/api/v1/mobile_app", headers: auth_headers(admin)
      expect(response.parsed_body["member_code"]).to eq(body["member_code"])
    end

    it "is a Pro tool: refused on Starter and during the trial" do
      company.subscription.update!(plan: :starter)

      get "/api/v1/mobile_app", headers: auth_headers(admin)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("pro_required")
    end

    it "is the admin's" do
      moderator = create(:staff_member, company: company, role: :moderator).user

      get "/api/v1/mobile_app", headers: auth_headers(moderator)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/mobile_app/regenerate" do
    it "replaces one key and the old one stops pairing" do
      company.ensure_app_keys!
      old_coach = company.coach_key

      post "/api/v1/mobile_app/regenerate", params: { audience: "coach" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["coach_key"]).not_to eq(old_coach)
      expect(response.parsed_body["member_code"]).to eq(company.reload.app_code)

      get "/api/v1/tenants/#{old_coach}/app_config"
      expect(response).to have_http_status(:not_found)
    end

    it "refuses an unknown audience" do
      post "/api/v1/mobile_app/regenerate", params: { audience: "everyone" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /api/v1/tenants/:code/app_config" do
    before { company.ensure_app_keys! }

    it "makes the member app with the member code — no sign-in needed" do
      get "/api/v1/tenants/#{company.app_code.upcase}/app_config"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["audience"]).to eq("member")
      expect(body["slug"]).to eq(company.app_code)
      expect(body["tenant"]["name"]).to eq("Studio Lumen")
      expect(body["api_base_url"]).to end_with("/api/v1")
      expect(body).not_to have_key("staff")
    end

    it "makes the staff app with the coach key, listing the active team to sign in as" do
      coach_record = create(:staff_member, company: company, role: :coach, coach: create(:coach, company: company))
      create(:staff_member, company: company, role: :moderator, active: false)

      get "/api/v1/tenants/#{company.coach_key}/app_config"

      body = response.parsed_body
      expect(body["audience"]).to eq("staff")
      expect(body["staff"].map { |s| s["id"] }).to eq([ coach_record.user_id ])
      expect(body["staff"].first).to include("coach" => true, "email" => coach_record.user.email)
    end

    it "404s on a code nobody has" do
      get "/api/v1/tenants/nope1234/app_config"

      expect(response).to have_http_status(:not_found)
    end

    it "pairs no new phone while the account's access is closed" do
      company.subscription.update!(active: false)

      get "/api/v1/tenants/#{company.app_code}/app_config"

      expect(response).to have_http_status(:forbidden)
    end

    it "does not open the app for a salle without paid Pro" do
      company.subscription.update!(plan: :starter)

      get "/api/v1/tenants/#{company.app_code}/app_config"

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("member_app_not_included")
    end
  end
end
