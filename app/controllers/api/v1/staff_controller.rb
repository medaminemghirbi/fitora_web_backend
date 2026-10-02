module Api
  module V1
    class StaffController < BaseController
      before_action :require_company!
      before_action :require_staff_manager!
      before_action :set_staff_member, only: [ :show, :update ]

      # GET /api/v1/staff
      def index
        staff = current_company.staff_members.includes(:user, :coach, :assigned_role)
                               .joins(:assigned_role).order("roles.position", "roles.name")
        render json: { staff: staff.map { |s| StaffMemberSerializer.new(s).as_json } }
      end

      # GET /api/v1/staff/:id
      def show
        render json: { staff_member: StaffMemberSerializer.new(@staff_member).as_json }
      end

      # POST /api/v1/staff
      def create
        user = User.new(user_params.merge(role: :staff, locale: user_params[:locale].presence || "fr"))
        staff_member = nil

        ActiveRecord::Base.transaction do
          user.save!
          staff_member = current_company.staff_members.create!(
            user: user,
            coach_id: staff_params[:coach_id],
            birthdate: staff_params[:birthdate],
            **role_assignment
          )
        end

        AuditLog.record!(
          company: current_company, user: current_user, action: "staff.created",
          auditable: staff_member, metadata: { role: staff_member.role_key, staff_email: user.email }
        )

        raw = user.generate_email_verification_token!
        AccountMailer.email_verification(user, raw).deliver_later

        # A refused save raises RecordInvalid, which ApplicationController
        # answers with the same 422 every other write gives.
        render json: { staff_member: StaffMemberSerializer.new(staff_member).as_json }, status: :created
      end

      # PATCH /api/v1/staff/:id
      def update
        previous_key = @staff_member.role_key
        attrs = { active: staff_params[:active], birthdate: staff_params[:birthdate], coach_id: staff_params[:coach_id] }
                  .compact.merge(role_assignment)

        if @staff_member.update(attrs)
          if previous_key != @staff_member.reload.role_key
            AuditLog.record!(
              company: current_company, user: current_user, action: "staff.role_changed",
              auditable: @staff_member, metadata: { from: previous_key, to: @staff_member.role_key }
            )
          end

          render json: { staff_member: StaffMemberSerializer.new(@staff_member).as_json }
        else
          render_errors(@staff_member)
        end
      end

      private

      # Staff management is admin-only now — no in-company staff role has full
      # access anymore, so there's no "staff-superadmin" exception to make here.
      def require_staff_manager!
        render_forbidden unless current_user.admin?
      end

      def set_staff_member
        @staff_member = current_company.staff_members.find(params[:id])
      end

      def user_params
        params.require(:staff_member).permit(:first_name, :last_name, :email, :phone, :password, :locale)
      end

      def staff_params
        params.require(:staff_member).permit(:role, :role_id, :active, :coach_id, :birthdate)
      end

      # Resolve an incoming assignment to the company's own Role row.
      #
      # `role_id` (the roles editor) is the real input. A bare `role` key
      # ("moderator", "coach") is still accepted because older clients
      # send it, and it means "the built-in role with that key, in this
      # company". Returns {} when neither is present, so an unrelated update
      # leaves the role alone.
      #
      # Both paths look the role up through current_company, so a role id
      # belonging to another gym resolves to nothing rather than being
      # assigned.
      def role_assignment
        if staff_params[:role_id].present?
          { assigned_role: current_company.roles.find(staff_params[:role_id]) }
        elsif staff_params[:role].present?
          role = current_company.roles.find_by(key: staff_params[:role].to_s)
          raise ActiveRecord::RecordNotFound, "Unknown role" if role.nil?

          { assigned_role: role }
        else
          {}
        end
      end
    end
  end
end
