require "rails_helper"

# What each role may NOT do, inside its own company.
#
# Tenant isolation (spec/requests/security/tenant_isolation_spec.rb) covers
# one gym reaching another's data. This file covers the other half: a
# legitimate login of one kind reaching something meant for a different kind.
#
# A refusal here is 403 — the caller is authenticated and the record is
# theirs to know about; they simply may not do this. That is the opposite of
# the cross-tenant case, which is 404 precisely so nothing is confirmed.
RSpec.describe "Security: role boundaries", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin) }

  let(:moderator) { create(:staff_member, company: company, role: :moderator) }
  let(:coach_staff) { create(:staff_member, company: company, role: :coach) }
  let(:superadmin) { create(:user, :superadmin) }
  let(:member) { create(:client, company: company) }

  describe "a moderator" do
    it "cannot read the gym's revenue" do
      get "/api/v1/admin/revenue", headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "cannot edit the activity catalogue" do
      activity = create(:activity, company: company)

      patch "/api/v1/activities/#{activity.id}", params: { activity: { name: "Renamed" } },
                                                 headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:forbidden)
      expect(activity.reload.name).not_to eq("Renamed")
    end

    it "cannot edit the plan catalogue" do
      plan = create(:contract_type, company: company)

      patch "/api/v1/contract_types/#{plan.id}", params: { contract_type: { name: "Renamed" } },
                                                 headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "cannot manage staff" do
      get "/api/v1/staff", headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "cannot edit the company's roles" do
      get "/api/v1/roles", headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "can still do the desk job it exists for" do
      get "/api/v1/clients", headers: auth_headers(moderator.user)
      expect(response).to have_http_status(:ok)

      get "/api/v1/payments", headers: auth_headers(moderator.user)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "a coach" do
    it "cannot read the gym's revenue" do
      get "/api/v1/admin/revenue", headers: auth_headers(coach_staff.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "cannot read payments" do
      get "/api/v1/payments", headers: auth_headers(coach_staff.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "cannot read the member list" do
      get "/api/v1/clients", headers: auth_headers(coach_staff.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "cannot edit an activity" do
      activity = create(:activity, company: company)

      patch "/api/v1/activities/#{activity.id}", params: { activity: { name: "Renamed" } },
                                                 headers: auth_headers(coach_staff.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "cannot sell a contract" do
      get "/api/v1/contracts", headers: auth_headers(coach_staff.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "cannot change the company's settings" do
      patch "/api/v1/company", params: { company: { name: "Renamed Gym" } },
                               headers: auth_headers(coach_staff.user)

      expect(response).to have_http_status(:forbidden)
      expect(company.reload.name).not_to eq("Renamed Gym")
    end
  end

  describe "any staff login" do
    it "cannot reach the platform superadmin console" do
      get "/api/v1/superadmin/companies", headers: auth_headers(moderator.user)
      expect(response).to have_http_status(:forbidden)

      get "/api/v1/superadmin/companies", headers: auth_headers(coach_staff.user)
      expect(response).to have_http_status(:forbidden)
    end

    it "cannot reach the member's own app" do
      get "/api/v1/me/profile", headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "cannot set the platform's subscription pricing" do
      patch "/api/v1/superadmin/subscription_pricing", params: { annual_discount_percent: 90 },
                                                  headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "an admin" do
    it "cannot reach the platform superadmin console" do
      get "/api/v1/superadmin/companies", headers: auth_headers(admin)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "a member" do
    it "cannot read the gym's member list" do
      get "/api/v1/clients", headers: auth_headers(member)

      expect(response).to have_http_status(:forbidden)
    end

    it "cannot read payments, contracts or revenue" do
      get "/api/v1/payments", headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)

      get "/api/v1/contracts", headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)

      get "/api/v1/admin/revenue", headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end

    it "cannot edit the gym's schedule" do
      activity = create(:activity, company: company)

      post "/api/v1/sessions",
           params: { session: { activity_id: activity.id, starts_at: 2.days.from_now,
                                ends_at: 2.days.from_now + 1.hour, capacity: 10 } },
           headers: auth_headers(member)

      expect(response).to have_http_status(:forbidden)
    end

    it "cannot reach the platform superadmin console" do
      get "/api/v1/superadmin/companies", headers: auth_headers(member)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "a platform superadmin" do
    it "has no company of their own to operate" do
      get "/api/v1/clients", headers: auth_headers(superadmin)

      expect(response).not_to have_http_status(:ok)
    end

    it "is given no permissions at all by the resolver" do
      expect(superadmin.permission_keys).to be_empty
      expect(superadmin.role_summary).to be_nil
    end
  end
end
