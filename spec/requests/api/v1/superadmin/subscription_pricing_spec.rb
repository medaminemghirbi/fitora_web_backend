require "rails_helper"

RSpec.describe "Api::V1::Superadmin::SubscriptionPricing", type: :request do
  let(:superadmin) { create(:user, :superadmin) }

  describe "GET /api/v1/superadmin/subscription_pricing" do
    it "returns both plans for the reference (TND) currency + the annual discount by default" do
      SubscriptionPrice.for("TND", plan: "starter").update!(monthly_cents: 19_000)

      get "/api/v1/superadmin/subscription_pricing", headers: auth_headers(superadmin)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["currency"]).to eq("TND")
      expect(body["annual_discount_percent"]).to eq(10)
      expect(body["currencies"]).to include("TND", "EUR")

      starter = body["plans"].find { |p| p["plan"] == "starter" }
      expect(starter["monthly_cents"]).to eq(19_000)
      expect(starter["annual_cents"]).to eq((19_000 * 12 * 0.9).round)
      expect(body["plans"].map { |p| p["plan"] }).to eq(%w[starter pro])
    end

    it "counts the accounts on each plan in that currency" do
      create(:subscription, :pro, company: create(:company, currency: "TND"))
      create(:subscription, company: create(:company, currency: "EUR"))

      get "/api/v1/superadmin/subscription_pricing", headers: auth_headers(superadmin)

      counts = response.parsed_body["plans"].to_h { |p| [ p["plan"], p["accounts_count"] ] }
      expect(counts).to eq("starter" => 0, "pro" => 1)
    end

    it "auto-seeds a requested currency's plans from the reference" do
      SubscriptionPrice.for("TND", plan: "starter").update!(monthly_cents: 17_000)

      get "/api/v1/superadmin/subscription_pricing", params: { currency: "EUR" }, headers: auth_headers(superadmin)

      body = response.parsed_body
      expect(body["currency"]).to eq("EUR")
      expect(body["plans"].find { |p| p["plan"] == "starter" }["monthly_cents"]).to eq(17_000)
    end

    it "is superadmin-only" do
      get "/api/v1/superadmin/subscription_pricing", headers: auth_headers(create(:user, :admin))
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PATCH /api/v1/superadmin/subscription_pricing" do
    it "updates a currency's plans and the global annual discount" do
      patch "/api/v1/superadmin/subscription_pricing",
            params: { currency: "EUR", plans: { "starter" => 4500, "pro" => 9000 }, annual_discount_percent: 15 },
            headers: auth_headers(superadmin)

      expect(response).to have_http_status(:ok)
      expect(SubscriptionPrice.for("EUR", plan: "starter").monthly_cents).to eq(4500)
      expect(SubscriptionPrice.for("EUR", plan: "pro").monthly_cents).to eq(9000)
      expect(PlatformSetting.current.annual_discount_percent).to eq(15)

      starter = response.parsed_body["plans"].find { |p| p["plan"] == "starter" }
      expect(starter["annual_cents"]).to eq((4500 * 12 * 0.85).round)
    end

    it "leaves a plan not mentioned in the request untouched" do
      SubscriptionPrice.for("EUR", plan: "pro").update!(monthly_cents: 9000)

      patch "/api/v1/superadmin/subscription_pricing", params: { currency: "EUR", plans: { "starter" => 4500 } }, headers: auth_headers(superadmin)

      expect(SubscriptionPrice.for("EUR", plan: "pro").monthly_cents).to eq(9000)
    end

    it "ignores a plan Gymly does not sell" do
      patch "/api/v1/superadmin/subscription_pricing", params: { currency: "EUR", plans: { "premium" => 1 } }, headers: auth_headers(superadmin)

      expect(response).to have_http_status(:ok)
      expect(SubscriptionPrice.where(plan: "premium")).to be_none
    end

    it "rejects a negative price" do
      patch "/api/v1/superadmin/subscription_pricing", params: { currency: "EUR", plans: { "pro" => -1 } }, headers: auth_headers(superadmin)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects an out-of-range discount" do
      patch "/api/v1/superadmin/subscription_pricing",
            params: { annual_discount_percent: 250 }, headers: auth_headers(superadmin)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
