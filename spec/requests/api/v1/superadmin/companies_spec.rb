require "rails_helper"

RSpec.describe "Api::V1::Superadmin::Companies", type: :request do
  let(:superadmin) { create(:user, :superadmin) }

  describe "authorization" do
    it "forbids an admin from accessing the superadmin companies list" do
      admin = create(:user, :admin)

      get "/api/v1/superadmin/companies", headers: auth_headers(admin)

      expect(response).to have_http_status(:forbidden)
    end

    it "forbids org-scoped staff from accessing the superadmin companies list" do
      staff = create(:staff_member)

      get "/api/v1/superadmin/companies", headers: auth_headers(staff.user)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/superadmin/companies" do
    it "lists every company across every admin, not just one" do
      company_a = create(:company)
      company_b = create(:company)
      create(:subscription, company: company_a)
      create(:subscription, company: company_b)

      get "/api/v1/superadmin/companies", headers: auth_headers(superadmin)

      ids = response.parsed_body["companies"].map { |o| o["id"] }
      expect(ids).to include(company_a.id, company_b.id)
    end

    it "filters by ?q= on company name, city or admin" do
      match = create(:company, name: "Zen Yoga Monastir", city: "Monastir")
      other = create(:company, name: "Iron Gym Tunis", city: "Tunis")

      get "/api/v1/superadmin/companies", params: { q: "monastir" }, headers: auth_headers(superadmin)

      ids = response.parsed_body["companies"].map { |o| o["id"] }
      expect(ids).to include(match.id)
      expect(ids).not_to include(other.id)
      expect(response.parsed_body["meta"]["total"]).to eq(1)
    end
  end

  describe "GET /api/v1/superadmin/companies/:id" do
    it "returns the company with its currency/locale and the option lists" do
      company = create(:company, currency: "TND", locale: "fr")

      get "/api/v1/superadmin/companies/#{company.id}", headers: auth_headers(superadmin)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["company"]).to include("currency" => "TND", "currency_symbol" => "DT", "locale" => "fr")
      expect(body["currency_options"].map { |c| c["code"] }).to include("TND", "EUR", "USD")
      expect(body["currency_options"].find { |c| c["code"] == "EUR" }).to include("symbol" => "€")
      expect(body["locale_options"]).to eq(%w[fr en ar])
    end
  end

  describe "PATCH /api/v1/superadmin/companies/:id/settings" do
    it "sets the tenant currency and language" do
      company = create(:company, currency: "TND", locale: "fr")

      patch "/api/v1/superadmin/companies/#{company.id}/settings",
            params: { company: { currency: "EUR", locale: "en" } },
            headers: auth_headers(superadmin)

      expect(response).to have_http_status(:ok)
      expect(company.reload).to have_attributes(currency: "EUR", locale: "en")
      expect(response.parsed_body["company"]).to include("currency_symbol" => "€")
    end

    it "422s on a currency outside the catalogue" do
      company = create(:company)
      patch "/api/v1/superadmin/companies/#{company.id}/settings",
            params: { company: { currency: "BTC" } }, headers: auth_headers(superadmin)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "422s on an unsupported language" do
      company = create(:company)
      patch "/api/v1/superadmin/companies/#{company.id}/settings",
            params: { company: { locale: "de" } }, headers: auth_headers(superadmin)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "is superadmin-only" do
      company = create(:company)
      patch "/api/v1/superadmin/companies/#{company.id}/settings",
            params: { company: { currency: "EUR" } }, headers: auth_headers(create(:user, :admin))
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "the account's plan" do
    it "moves the account to Pro, for every salle the admin runs" do
      company = create(:company)
      other_company = create(:company, admin: company.admin)
      create(:subscription, company: company)

      patch "/api/v1/superadmin/companies/#{company.id}/subscription",
            params: { plan: "pro" }, headers: auth_headers(superadmin)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["company"]
      expect(body["plan"]).to eq("pro")
      expect(body["subscription"]["member_app"]).to be(true)
      expect(body["account_companies"].map { |c| c["id"] }).to eq([ company.id, other_company.id ])
      expect(other_company.reload.subscription).to be_pro
      expect(other_company).to be_member_app
    end

    it "logs the change of plan as that" do
      company = create(:company)
      create(:subscription, company: company)

      patch "/api/v1/superadmin/companies/#{company.id}/subscription",
            params: { plan: "pro" }, headers: auth_headers(superadmin)

      log = AuditLog.last
      expect(log.action).to eq("subscription.plan_changed")
      expect(log.metadata).to include("plan_from" => "starter", "plan" => "pro")
    end

    it "refuses a plan Gymly does not sell" do
      company = create(:company)
      create(:subscription, company: company)

      patch "/api/v1/superadmin/companies/#{company.id}/subscription",
            params: { plan: "premium" }, headers: auth_headers(superadmin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(company.subscription.reload).to be_starter
    end

    it "prices and labels the next invoice at the plan" do
      company = create(:company)
      create(:subscription, :pro, company: company)
      SubscriptionPrice.for("TND", plan: "pro").update!(monthly_cents: 30_000)

      post "/api/v1/superadmin/companies/#{company.id}/invoices", headers: auth_headers(superadmin)

      expect(response.parsed_body["invoice"]).to include("plan" => "pro", "amount" => 300.0)
    end
  end

  describe "POST /api/v1/superadmin/companies/:id/impersonate" do
    it "issues a real session for the company's admin, not the superadmin" do
      company = create(:company)

      post "/api/v1/superadmin/companies/#{company.id}/impersonate", headers: auth_headers(superadmin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["user"]["id"]).to eq(company.admin.id)
      expect(response.parsed_body["user"]["role"]).to eq("admin")
      expect(response.parsed_body["token"]).to be_present
    end

    it "the issued token actually authenticates as the admin on a normal endpoint" do
      company = create(:company)

      post "/api/v1/superadmin/companies/#{company.id}/impersonate", headers: auth_headers(superadmin)
      token = response.parsed_body["token"]

      get "/api/v1/company", headers: { "Authorization" => "Bearer #{token}" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["company"]["id"]).to eq(company.id)
    end

    it "records who impersonated in the audit log" do
      company = create(:company)

      post "/api/v1/superadmin/companies/#{company.id}/impersonate", headers: auth_headers(superadmin)

      log = AuditLog.order(:created_at).last
      expect(log.action).to eq("superadmin.impersonation_started")
      expect(log.company_id).to eq(company.id)
      expect(log.metadata["superadmin_id"]).to eq(superadmin.id)
    end

    it "forbids a non-superadmin from impersonating" do
      company = create(:company)
      admin = create(:user, :admin)

      post "/api/v1/superadmin/companies/#{company.id}/impersonate", headers: auth_headers(admin)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "what an activation decision needs to know" do
    it "reports what the gym is actually doing with Gymly" do
      company = create(:company)
      create(:subscription, company: company)
      activity = create(:activity, company: company)
      create(:session, company: company, activity: activity, starts_at: 3.days.ago, ends_at: 3.days.ago + 1.hour)
      create(:session, company: company, activity: activity, starts_at: 90.days.ago, ends_at: 90.days.ago + 1.hour)
      create(:client, company: company)

      get "/api/v1/superadmin/companies/#{company.id}", headers: auth_headers(superadmin)

      usage = response.parsed_body["company"]["usage"]
      expect(usage["clients"]).to eq(1)
      expect(usage["activities"]).to eq(1)
      # The old session counts towards "ever", never towards the last month.
      expect(usage["sessions_last_30_days"]).to eq(1)
      expect(usage["last_session_at"]).to be_present
    end

    it "reads zero for a gym that signed up and never came back" do
      company = create(:company)
      create(:subscription, company: company)

      get "/api/v1/superadmin/companies/#{company.id}", headers: auth_headers(superadmin)

      usage = response.parsed_body["company"]["usage"]
      expect(usage.values_at("clients", "staff", "activities", "sessions_last_30_days")).to all(eq(0))
      expect(usage["last_session_at"]).to be_nil
    end
  end
  describe "PATCH /api/v1/superadmin/companies/:id/subscription" do
    it "opens and closes access, because access is a boolean" do
      company = create(:company)
      create(:subscription, company: company)

      patch "/api/v1/superadmin/companies/#{company.id}/subscription",
            params: { active: false }, headers: auth_headers(superadmin)

      expect(response).to have_http_status(:ok)
      expect(company.subscription.reload).not_to be_active
      expect(AuditLog.last.action).to eq("subscription.access_suspended")
    end

    it "creates a subscription for a company that has none yet" do
      company = create(:company)

      patch "/api/v1/superadmin/companies/#{company.id}/subscription",
            params: { billing_period: "yearly" }, headers: auth_headers(superadmin)

      expect(response).to have_http_status(:ok)
      expect(company.reload.subscription.billing_period).to eq("yearly")
    end

    it "is superadmin-only" do
      company = create(:company)
      create(:subscription, company: company)

      patch "/api/v1/superadmin/companies/#{company.id}/subscription",
            params: { active: false }, headers: auth_headers(company.admin)

      expect(response).to have_http_status(:forbidden)
    end
    # Choosing what the next invoice covers is not an access event, and
    # the admin's feed must not be told access was restored.
    it "logs a change of formula as that, not as access restored" do
      company = create(:company)
      create(:subscription, company: company, billing_period: :monthly)

      patch "/api/v1/superadmin/companies/#{company.id}/subscription",
            params: { billing_period: "yearly" }, headers: auth_headers(superadmin)

      expect(AuditLog.last.action).to eq("subscription.billing_period_changed")
    end
  end

  # A formula chosen during the free days only says what the payment will
  # buy. Access stays the trial's until money arrives, and the paid year
  # starts where the gift ends.
  describe "leaving the trial" do
    let(:company) { create(:company) }

    before do
      create(:subscription, company: company, billing_period: :monthly)
      create(:invoice, :trial, company: company)
    end

    it "keeps the gym on trial when only the formula changes, and says what paying would issue" do
      patch "/api/v1/superadmin/companies/#{company.id}/subscription",
            params: { billing_period: "yearly" }, headers: auth_headers(superadmin)

      body = response.parsed_body["company"]
      trial_end = Date.current + (Subscription::TRIAL_DAYS - 1)
      expect(body["subscription"]["trial"]).to be(true)
      expect(body["next_invoice"]).to eq(
        "period_start" => (trial_end + 1).iso8601,
        "period_end" => (trial_end >> 12).iso8601,
        "amount_cents" => company.annual_subscription_cents
      )
    end

    it "ends the trial with the invoice the preview promised" do
      patch "/api/v1/superadmin/companies/#{company.id}/subscription",
            params: { billing_period: "yearly" }, headers: auth_headers(superadmin)
      promised = response.parsed_body["company"]["next_invoice"]

      post "/api/v1/superadmin/companies/#{company.id}/invoices", headers: auth_headers(superadmin)

      issued = response.parsed_body["invoice"]
      expect(issued.values_at("period_start", "period_end")).to eq(promised.values_at("period_start", "period_end"))
      expect((issued["amount"] * 100).round).to eq(promised["amount_cents"])
      expect(issued["billing_period"]).to eq("yearly")
      expect(response.parsed_body["company"]["subscription"]["trial"]).to be(false)
    end
  end

  describe "GET /api/v1/superadmin/companies?closed=1" do
    it "narrows to the gyms whose access is shut, and counts them either way" do
      create(:subscription, company: create(:company, name: "Ouverte"))
      create(:subscription, :closed, company: create(:company, name: "Fermée"))

      get "/api/v1/superadmin/companies", headers: auth_headers(superadmin)
      expect(response.parsed_body["closed_count"]).to eq(1)
      expect(response.parsed_body["companies"].map { |c| c["name"] }).to eq([ "Fermée", "Ouverte" ])

      get "/api/v1/superadmin/companies", params: { closed: "1" }, headers: auth_headers(superadmin)
      expect(response.parsed_body["companies"].map { |c| c["name"] }).to eq([ "Fermée" ])
    end
  end

  describe "the money arriving" do
    let(:company) { create(:company) }

    it "issues one invoice for the next uncovered period and reopens access" do
      subscription = create(:subscription, :closed, company: company, billing_period: :monthly)
      create(:invoice, company: company, period_start: Date.new(2026, 7, 1), period_end: Date.new(2026, 7, 31))

      expect {
        post "/api/v1/superadmin/companies/#{company.id}/invoices", headers: auth_headers(superadmin)
      }.to change(Invoice, :count).by(1)

      expect(response).to have_http_status(:created)
      issued = company.subscription.invoices.newest_first.first
      expect(issued.period_start).to eq(Date.new(2026, 8, 1))
      expect(issued.period_end).to eq(Date.new(2026, 8, 31))
      expect(subscription.reload).to be_active
      expect(AuditLog.last.action).to eq("subscription.invoice_issued")
    end

    it "freezes the amount, so a later price change cannot rewrite it" do
      create(:subscription, company: company, billing_period: :monthly)

      post "/api/v1/superadmin/companies/#{company.id}/invoices", headers: auth_headers(superadmin)
      issued_cents = response.parsed_body["invoice"]["amount"] * 100

      expect(issued_cents.round).to eq(company.monthly_subscription_cents)
    end

    it "tells the gym's admin it was issued" do
      create(:subscription, company: company)

      expect {
        post "/api/v1/superadmin/companies/#{company.id}/invoices", headers: auth_headers(superadmin)
      }.to change { company.admin.notifications.where(kind: "invoice_issued").count }.by(1)
    end

    it "voids one issued in error" do
      create(:subscription, company: company)
      invoice = create(:invoice, company: company)

      expect {
        delete "/api/v1/superadmin/companies/#{company.id}/invoices/#{invoice.id}", headers: auth_headers(superadmin)
      }.to change(Invoice, :count).by(-1)

      expect(AuditLog.last.action).to eq("subscription.invoice_voided")
    end

    it "is closed to anyone who is not a Gymly superadmin" do
      create(:subscription, company: company)

      post "/api/v1/superadmin/companies/#{company.id}/invoices", headers: auth_headers(company.admin)

      expect(response).to have_http_status(:forbidden)
    end
  end
end
