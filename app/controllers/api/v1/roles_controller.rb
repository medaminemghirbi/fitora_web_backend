module Api
  module V1
    # The company's staff roles — built-in (admin / moderator / coach) plus
    # any custom ones. Admin-only: this is where web access is defined.
    class RolesController < BaseController
      before_action :require_company!
      before_action :require_admin!
      # Reading the roles stays open (the team page assigns them); shaping
      # them — custom roles, permissions — is a Pro tool.
      before_action :require_pro!, only: [ :create, :update, :destroy ]
      before_action :set_role, only: [ :update, :destroy ]

      # GET /api/v1/roles
      def index
        render json: {
          roles: current_company.roles.ordered.map { |r| RoleSerializer.new(r).as_json },
          permission_catalog: Permission::CATALOG
        }
      end

      # POST /api/v1/roles — a custom role
      def create
        role = current_company.roles.new(role_params.merge(builtin: false))

        if role.save
          render json: { role: RoleSerializer.new(role).as_json }, status: :created
        else
          render_error(role)
        end
      end

      # PATCH /api/v1/roles/:id — rename / re-permission (not the admin role)
      def update
        return render(json: { error: "The Admin role cannot be edited." }, status: :unprocessable_content) if @role.key == "admin"

        # A built-in role keeps its key even if renamed.
        if @role.update(role_params)
          render json: { role: RoleSerializer.new(@role).as_json }
        else
          render_error(@role)
        end
      end

      # DELETE /api/v1/roles/:id — custom, unused roles only
      def destroy
        unless @role.deletable?
          reason = @role.builtin? ? "A built-in role cannot be deleted." : "Staff accounts still use this role."
          return render json: { error: reason }, status: :unprocessable_content
        end

        @role.destroy
        head :no_content
      end

      private

      def set_role
        @role = current_company.roles.find(params[:id])
      end

      def role_params
        params.require(:role).permit(:name, permissions: [])
      end

      def render_error(record)
        render_errors(record)
      end
    end
  end
end
