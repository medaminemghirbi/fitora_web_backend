require "rails_helper"

RSpec.describe "Api::V1::Staff", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin) }

  describe "authorization" do
    it "lets the admin create a staff member" do
      post "/api/v1/staff",
           params: { staff_member: { first_name: "Sara", last_name: "Desk", email: "sara@fitora.test", password: "password123", role: "moderator" } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["staff_member"]["role_key"]).to eq("moderator")
    end

    it "is never blocked by any staff count — no plans, no limits" do
      create_list(:staff_member, 5, company: company)

      post "/api/v1/staff",
           params: { staff_member: { first_name: "Sara", last_name: "Desk", email: "sara@fitora.test", password: "password123", role: "moderator" } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
    end

    it "forbids a non-admin staff member from creating staff — only the admin manages staff" do
      staff = create(:staff_member, company: company, role: :moderator)

      post "/api/v1/staff",
           params: { staff_member: { first_name: "New", last_name: "Hire", email: "hire2@fitora.test", password: "password123", role: "coach" } },
           headers: auth_headers(staff.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "forbids a coach from creating staff" do
      coach_staff = create(:staff_member, company: company, role: :coach)

      post "/api/v1/staff",
           params: { staff_member: { first_name: "New", last_name: "Hire", email: "hire3@fitora.test", password: "password123", role: "coach" } },
           headers: auth_headers(coach_staff.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "assigns a custom role by role_id and resolves its permissions" do
      accountant = create(:role, company: company, name: "Comptable", permissions: %w[payments reports])

      post "/api/v1/staff",
           params: { staff_member: { first_name: "Ali", last_name: "K", email: "ali@fitora.test", password: "password123", role_id: accountant.id } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      body = response.parsed_body["staff_member"]
      expect(body["role_key"]).to eq(accountant.key)
      # There is no second "underlying kind" any more — the role IS the role.
      expect(body["is_coach"]).to be(false)
      expect(body["permissions"]).to match_array(%w[payments reports])
    end

    it "the Fitora platform superadmin (User#role == superadmin) has no special access to an company's staff endpoint" do
      platform_superadmin = create(:user, :superadmin)

      get "/api/v1/staff", headers: auth_headers(platform_superadmin)

      # The platform superadmin has no company of their own, so this 422s on
      # require_company! rather than ever leaking another org's staff.
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "audit logging" do
    it "logs a staff role change" do
      staff = create(:staff_member, company: company, role: :coach)

      patch "/api/v1/staff/#{staff.id}", params: { staff_member: { role: "moderator" } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      log = AuditLog.last
      expect(log.action).to eq("staff.role_changed")
      expect(log.company_id).to eq(company.id)
    end
  end

  describe "company isolation" do
    it "never exposes another company's staff" do
      other_org_staff = create(:staff_member)

      get "/api/v1/staff", headers: auth_headers(admin)

      ids = response.parsed_body["staff"].map { |s| s["id"] }
      expect(ids).not_to include(other_org_staff.id)
    end
  end
end
