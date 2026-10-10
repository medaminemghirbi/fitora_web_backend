require "rails_helper"

# What stays the admin's even when a role holds the domain's permission:
# reading what the gym earns, refunds, taking a member off the books, and
# bulk exports. A moderator holds `payments`, `contracts` and `clients` by
# default, so every example here is a moderator being refused (or shown
# less) where the admin is not.
RSpec.describe "Security: admin-reserved actions", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin) }
  let(:moderator) { create(:staff_member, company: company, role: :moderator).user }
  let(:client) { create(:client, company: company) }

  describe "revenue figures" do
    before { create(:payment, company: company, client: client) }

    it "leaves the payments totals out for a moderator" do
      get "/api/v1/payments", headers: auth_headers(moderator)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["payments"]).not_to be_empty
      expect(response.parsed_body).not_to have_key("totals")
    end

    it "gives the admin the payments totals" do
      get "/api/v1/payments", headers: auth_headers(admin)

      expect(response.parsed_body["totals"]).to include("collected_total")
    end

    it "gives a role granted `revenue` the payments totals" do
      company.roles.find_by(key: "moderator").update!(permissions: %w[payments revenue])

      get "/api/v1/payments", headers: auth_headers(moderator)

      expect(response.parsed_body["totals"]).to include("collected_total")
    end

    it "keeps only the expiring count in the contracts totals for a moderator" do
      get "/api/v1/contracts", headers: auth_headers(moderator)

      expect(response.parsed_body["totals"].keys).to eq([ "expiring_soon" ])
    end

    it "gives the admin the contract portfolio figures" do
      get "/api/v1/contracts", headers: auth_headers(admin)

      expect(response.parsed_body["totals"]).to include("portfolio_value", "average_basket", "unpaid_value")
    end
  end

  describe "refunds" do
    let(:payment) { create(:payment, company: company, client: client) }

    it "refuses a moderator" do
      post "/api/v1/payments/#{payment.id}/refund", headers: auth_headers(moderator)

      expect(response).to have_http_status(:forbidden)
      expect(payment.reload.status).to eq("paid")
    end

    it "lets the admin refund" do
      post "/api/v1/payments/#{payment.id}/refund", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(payment.reload.status).to eq("refunded")
    end
  end

  describe "removing a member" do
    it "refuses a moderator" do
      delete "/api/v1/clients/#{client.id}", headers: auth_headers(moderator)

      expect(response).to have_http_status(:forbidden)
      expect(company.memberships.exists?(client_id: client.id)).to be(true)
    end

    it "lets the admin remove them" do
      delete "/api/v1/clients/#{client.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:no_content)
    end
  end

  describe "CSV exports" do
    # CSV import / export is a Pro tool.
    before { create(:subscription, :pro, company: company) }

    before { create(:payment, company: company, client: client) }

    {
      "members list" => "/api/v1/clients?format=csv",
      "payments list" => "/api/v1/payments?format=csv",
      "bookings list" => "/api/v1/bookings?format=csv",
      "members export" => "/api/v1/data_exchange/clients/export",
      "payments export" => "/api/v1/data_exchange/payments/export",
      "contracts export" => "/api/v1/data_exchange/contracts/export"
    }.each do |name, path|
      it "refuses the #{name} to a moderator and serves it to the admin" do
        get path, headers: auth_headers(moderator)
        expect(response).to have_http_status(:forbidden)

        get path, headers: auth_headers(admin)
        expect(response).to have_http_status(:ok)
      end
    end

    it "still lets a moderator download an import template" do
      get "/api/v1/data_exchange/clients/template", headers: auth_headers(moderator)

      expect(response).to have_http_status(:ok)
    end
  end
end
