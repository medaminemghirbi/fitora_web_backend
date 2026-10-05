module Api
  module V1
    module Admin
      class ReportsController < BaseController
        before_action :require_admin!
        before_action :require_company!

        # GET /api/v1/admin/reports/export?period_type=month&period=2026-02
        # GET /api/v1/admin/reports/export?period_type=year&period=2026
        def export
          period = Reports::Period.parse(period_type: params[:period_type], period: params[:period])
          package = Reports::CompanyWorkbook.call(company: current_company, period: period)

          AuditLog.record!(
            company: current_company, user: current_user, action: "report.exported",
            auditable: current_company, metadata: { period: period.slug }
          )

          send_data package.to_stream.read,
                     filename: "fitora-rapport-#{period.slug}.xlsx",
                     type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                     disposition: "attachment"
        rescue Reports::Period::InvalidPeriod => e
          render json: { error: e.message }, status: :unprocessable_content
        end
      end
    end
  end
end
