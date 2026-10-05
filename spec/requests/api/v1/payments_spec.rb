require "rails_helper"

RSpec.describe "Api::V1::Payments", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin) }

  describe "GET /api/v1/payments" do
    it "never exposes another company's payments" do
      create(:payment, company: company, client: create(:client, company: company))
      other_company = create(:company)
      other_payment = create(:payment, company: other_company, client: create(:client, company: other_company))

      get "/api/v1/payments", headers: auth_headers(admin)

      ids = response.parsed_body["payments"].map { |p| p["id"] }
      expect(ids).not_to include(other_payment.id)
    end

    it "forbids a coach from listing payments" do
      coach_staff = create(:staff_member, company: company, role: :coach)

      get "/api/v1/payments", headers: auth_headers(coach_staff.user)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/payments/:id" do
    it "404s for a payment belonging to another company" do
      other_company = create(:company)
      other_payment = create(:payment, company: other_company, client: create(:client, company: other_company))

      get "/api/v1/payments/#{other_payment.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/payments" do
    it "rejects a client_id belonging to another company" do
      other_client = create(:client)

      post "/api/v1/payments", params: { client_id: other_client.id, amount: 50, payment_method: "cash" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "logs an audit entry for the recorded payment" do
      client = create(:client, company: company)
      contract = create(:contract, client: client, contract_type: create(:contract_type, company: company))

      post "/api/v1/payments",
           params: { client_id: client.id, amount: 50, payment_method: "cash", contract_id: contract.id },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      log = AuditLog.last
      expect(log.action).to eq("payment.recorded")
      expect(log.company_id).to eq(company.id)
    end
  end

  describe "POST /api/v1/payments/:id/refund" do
    it "logs an audit entry for the refund" do
      payment = create(:payment, company: company, client: create(:client, company: company), status: :paid)

      post "/api/v1/payments/#{payment.id}/refund", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      log = AuditLog.last
      expect(log.action).to eq("payment.refunded")
      expect(log.company_id).to eq(company.id)
    end
  end

  describe "the list's rail counts and cash totals" do
    it "counts each status and sums what was actually collected" do
      client = create(:client, company: company)
      create(:payment, company: company, client: client, status: :paid, amount: 250, paid_at: Time.current)
      create(:payment, company: company, client: client, status: :paid, amount: 150, paid_at: Time.current)
      create(:payment, company: company, client: client, status: :refunded, amount: 100)

      get "/api/v1/payments", headers: auth_headers(admin)

      body = response.parsed_body
      expect(body["counts"]["all"]).to eq(3)
      expect(body["counts"]["paid"]).to eq(2)
      expect(body["counts"]["refunded"]).to eq(1)
      expect(body["totals"]["collected_this_month"]).to eq(400.0)
      expect(body["totals"]["refunded_value"]).to eq(100.0)
      expect(body["totals"]["average_payment"]).to eq(200.0)
    end
  end
end
