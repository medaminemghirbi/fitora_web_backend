require "rails_helper"

RSpec.describe "Api::V1::Admin::Reports", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin) }

  describe "GET /api/v1/admin/reports/export" do
    it "returns a styled .xlsx workbook for a monthly period" do
      client = create(:client, company: company)
      create(:payment, company: company, client: client, amount: 100, status: :paid, paid_at: Time.current)

      get "/api/v1/admin/reports/export",
          params: { period_type: "month", period: Date.current.strftime("%Y-%m") },
          headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to eq("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
      expect(response.headers["Content-Disposition"]).to include("fitora-rapport-")
      expect(response.body.bytesize).to be > 0
    end

    it "returns a workbook for a yearly period" do
      get "/api/v1/admin/reports/export", params: { period_type: "year", period: Date.current.year.to_s }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
    end

    it "logs an audit entry for the export" do
      get "/api/v1/admin/reports/export", params: { period_type: "year", period: Date.current.year.to_s }, headers: auth_headers(admin)

      log = AuditLog.last
      expect(log.action).to eq("report.exported")
      expect(log.company_id).to eq(company.id)
    end

    it "rejects an invalid period" do
      get "/api/v1/admin/reports/export", params: { period_type: "month", period: "not-a-period" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "forbids staff — this export is admin-only" do
      staff = create(:staff_member, company: company, role: :moderator)

      get "/api/v1/admin/reports/export", params: { period_type: "month", period: "2026-01" }, headers: auth_headers(staff.user)

      expect(response).to have_http_status(:forbidden)
    end
  end
end
