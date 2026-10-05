require "rails_helper"

RSpec.describe "Api::V1::Superadmin::Metrics", type: :request do
  let(:superadmin) { create(:user, :superadmin) }

  describe "who may ask" do
    it "refuses a company admin" do
      admin = create(:user, :admin)
      create(:company, admin: admin)

      get "/api/v1/superadmin/metrics", headers: auth_headers(admin)

      expect(response).to have_http_status(:forbidden)
    end

    it "refuses a staff member" do
      company = create(:company)
      staff = create(:staff_member, company: company, role: :moderator)

      get "/api/v1/superadmin/metrics", headers: auth_headers(staff.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "refuses a member" do
      get "/api/v1/superadmin/metrics", headers: auth_headers(create(:client, company: create(:company)))

      expect(response).to have_http_status(:forbidden)
    end

    it "refuses an unauthenticated caller" do
      get "/api/v1/superadmin/metrics"

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/superadmin/metrics" do
    it "counts every company, and how many still have the door open" do
      create(:subscription, company: create(:company), active: true)
      create(:subscription, company: create(:company), active: false)

      get "/api/v1/superadmin/metrics", headers: auth_headers(superadmin)

      expect(response).to have_http_status(:ok)
      companies = response.parsed_body["companies"]
      expect(companies["total"]).to eq(2)
      expect(companies["open"]).to eq(1)
      expect(companies["locked"]).to eq(1)
    end

    it "always has open and locked adding up to the total" do
      create(:subscription, company: create(:company), active: true)
      create(:company) # no subscription row at all

      get "/api/v1/superadmin/metrics", headers: auth_headers(superadmin)

      companies = response.parsed_body["companies"]
      expect(companies["open"] + companies["locked"]).to eq(companies["total"])
      expect(companies["locked"]).to eq(1)
    end

    it "separates this month's signups from last month's" do
      travel_to(2.months.ago) { create(:company) }
      travel_to(1.month.ago.beginning_of_month + 2.days) { create(:company) }
      create(:company)

      get "/api/v1/superadmin/metrics", headers: auth_headers(superadmin)

      companies = response.parsed_body["companies"]
      expect(companies["new_this_month"]).to eq(1)
      expect(companies["new_last_month"]).to eq(1)
      expect(companies["total"]).to eq(3)
    end

    it "counts members across the whole platform" do
      create(:client, company: create(:company))
      create(:client, company: create(:company))

      get "/api/v1/superadmin/metrics", headers: auth_headers(superadmin)

      expect(response.parsed_body["members"]["total"]).to eq(2)
    end

    it "reports whether gyms are actually running sessions, not just signed up" do
      company = create(:company)
      activity = create(:activity, company: company)
      recent = create(:session, company: company, activity: activity,
                                starts_at: 2.days.ago, ends_at: 2.days.ago + 1.hour)
      create(:booking, session: recent, client: create(:client, company: company))
      create(:session, company: company, activity: activity,
                       starts_at: 90.days.ago, ends_at: 90.days.ago + 1.hour)

      get "/api/v1/superadmin/metrics", headers: auth_headers(superadmin)

      activity_json = response.parsed_body["activity"]
      expect(activity_json["sessions_last_30_days"]).to eq(1)
      expect(activity_json["bookings_last_30_days"]).to eq(1)
      expect(activity_json["companies_with_activity"]).to eq(1)
    end

    it "reports Fitora's own money in the reference currency" do
      company = create(:company)
      create(:invoice, company: company, amount_cents: 12_000, issued_at: Time.current)

      get "/api/v1/superadmin/metrics", headers: auth_headers(superadmin)

      money = response.parsed_body["money"]
      expect(money["invoiced_this_month_cents"]).to eq(12_000)
      expect(money["currency"]).to eq(SubscriptionPrice::REFERENCE_CURRENCY)
      expect(money).to have_key("arrears_cents")
    end

    it "leaves out an invoice issued before this month" do
      create(:invoice, company: create(:company), amount_cents: 9_999, issued_at: 2.months.ago)

      get "/api/v1/superadmin/metrics", headers: auth_headers(superadmin)

      expect(response.parsed_body["money"]["invoiced_this_month_cents"]).to eq(0)
    end

    it "lists the five newest companies, newest first" do
      6.times { |i| travel_to(i.days.ago) { create(:company, name: "Gym #{i}") } }

      get "/api/v1/superadmin/metrics", headers: auth_headers(superadmin)

      recent = response.parsed_body["recent_companies"]
      expect(recent.size).to eq(5)
      expect(recent.first["name"]).to eq("Gym 0")
    end

    it "carries no member, booking or payment of any gym's" do
      company = create(:company)
      create(:client, company: company, first_name: "Private")

      get "/api/v1/superadmin/metrics", headers: auth_headers(superadmin)

      # Aggregates only. The superadmin console reaches a gym's own records by
      # impersonation, which is audited, and by no other route.
      expect(response.body).not_to include("Private")
      expect(response.parsed_body.keys)
        .to contain_exactly("companies", "members", "activity", "money", "recent_companies")
    end
  end
end
