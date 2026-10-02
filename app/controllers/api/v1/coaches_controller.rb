module Api
  module V1
    class CoachesController < BaseController
      before_action :require_company!
      # The coach list is schedule reference data (assign a coach to a
      # session); managing coach records is the :coaches capability.
      before_action -> { require_schedule_reference_read!(:coaches) }, only: [ :index, :show ]
      before_action -> { require_capability!(:coaches) }, only: [ :create, :update, :destroy, :set_login ]
      before_action :set_coach, only: [ :show, :update, :destroy, :set_login ]

      # GET /api/v1/coaches
      def index
        render json: { coaches: current_company.coaches.includes(:staff_member).order(:first_name).map { |c| CoachSerializer.new(c).as_json } }
      end

      # GET /api/v1/coaches/:id
      def show
        render json: { coach: CoachSerializer.new(@coach).as_json }
      end

      # POST /api/v1/coaches
      def create
        coach = current_company.coaches.new(coach_params)

        if coach.save
          render json: { coach: CoachSerializer.new(coach.reload).as_json }, status: :created
        else
          render_errors(coach)
        end
      end

      # PATCH /api/v1/coaches/:id
      def update
        if @coach.update(coach_params)
          render json: { coach: CoachSerializer.new(@coach).as_json }
        else
          render_errors(@coach)
        end
      end

      # DELETE /api/v1/coaches/:id — soft deactivate
      def destroy
        @coach.update!(active: false)
        render json: { coach: CoachSerializer.new(@coach).as_json }
      end

      # POST /api/v1/coaches/:id/login — provisions (or resets) the coach's
      # own login. Reached through the :coaches capability, which moderators
      # hold. It resets whatever login is attached to the coach, so below the
      # admin it only touches a login on the coach role: an admin can link a
      # coach to a moderator's or a full-access login, and resetting that one
      # would hand its access to whoever did it.
      def set_login
        attached = @coach.staff_member
        if attached && !current_user.admin? && attached.role_key != "coach"
          return render_forbidden("Only the admin can change this login.")
        end

        @coach.set_login!(email: params[:email], password: params[:password])
        AuditLog.record!(
          company: current_company, user: current_user, action: "coach.login_set",
          auditable: @coach, metadata: { email: params[:email] }
        )
        render json: { coach: CoachSerializer.new(@coach.reload).as_json }
      end

      private

      def set_coach
        @coach = current_company.coaches.find(params[:id])
      end

      def coach_params
        params.require(:coach).permit(:first_name, :last_name, :email, :phone, :bio, :photo_url, :active, :birthdate)
      end
    end
  end
end
