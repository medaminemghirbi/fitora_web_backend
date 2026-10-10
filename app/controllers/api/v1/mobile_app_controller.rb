module Api
  module V1
    # Settings → Application mobile: the salle's two keys and their QR codes,
    # and a way to replace either. A Pro tool (paid Pro only).
    class MobileAppController < BaseController
      before_action :require_company!
      before_action :require_admin!
      before_action :require_pro!

      # GET /api/v1/mobile_app
      def show
        render json: keys_json(current_company.ensure_app_keys!)
      end

      # POST /api/v1/mobile_app/regenerate { audience: "member" | "coach" }
      def regenerate
        audience = params[:audience].to_s
        return render_errors("Unknown audience") unless %w[member coach].include?(audience)

        current_company.ensure_app_keys!.regenerate_app_key!(audience)
        AuditLog.record!(
          company: current_company, user: current_user, action: "mobile_app.key_regenerated",
          auditable: current_company, metadata: { audience: audience }
        )
        render json: keys_json(current_company)
      end

      private

      def keys_json(company)
        {
          member_code: company.app_code,
          coach_key: company.coach_key,
          member_qr_svg: qr_svg(company.app_code),
          coach_qr_svg: qr_svg(company.coach_key)
        }
      end

      def qr_svg(text)
        RQRCode::QRCode.new(text).as_svg(module_size: 4, standalone: true, use_path: true, viewbox: true)
      end
    end
  end
end
