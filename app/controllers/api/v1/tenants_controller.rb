module Api
  module V1
    # GET /api/v1/tenants/:code/app_config — public: what the generic Fitora
    # app asks before anyone signs in, to become one salle's app
    # (mobile/src/lib/tenant-config.ts). The code is the salle's member code
    # (the member app) or its coach key (the staff app, which also gets the
    # team to pick an account from).
    #
    # The mobile app is a Pro feature: a salle not on a paid Pro period, or
    # whose access is closed, answers 403 `member_app_not_included`. An unknown code is a plain 404,
    # so a guess learns nothing. Throttled per IP (config/initializers/
    # rack_attack.rb).
    class TenantsController < ApplicationController
      def app_config
        company, audience = Company.find_by_app_key(params[:code])
        return render json: { error: "Gym not found" }, status: :not_found if company.nil?

        # A closed account (suspended, or unpaid) pairs no new phone either.
        unless company.member_app? && company.subscription&.active?
          return render json: {
            error: "member_app_not_included",
            message: "This gym's plan does not include the mobile app."
          }, status: :forbidden
        end

        body = {
          audience: audience,
          slug: company.app_code,
          tenant: tenant_json(company),
          api_base_url: "#{request.base_url}/api/v1"
        }
        body[:staff] = staff_json(company) if audience == :staff
        render json: body
      end

      private

      def tenant_json(company)
        logo = company.brand_logo
        {
          name: company.name,
          primary_color: company.brand_color,
          logo_url: logo && "#{request.base_url}#{Rails.application.routes.url_helpers.rails_blob_path(logo, only_path: true)}",
          locale: company.locale,
          support_email: company.email.presence,
          show_platform_branding: true
        }
      end

      # Everyone on the team who can sign in, to pick from on the staff app.
      def staff_json(company)
        company.staff_members.active.includes(:user, :assigned_role).filter_map do |record|
          user = record.user
          next unless user&.active?

          {
            id: user.id,
            first_name: user.first_name,
            last_name: user.last_name,
            full_name: user.full_name,
            email: user.email,
            role: record.assigned_role&.name.to_s,
            coach: record.coach_id.present?
          }
        end.sort_by { |s| s[:full_name].to_s.downcase }
      end
    end
  end
end
