module Api
  module V1
    class RecurringSchedulesController < BaseController
      before_action :require_company!
      before_action -> { require_capability!(:sessions) }, only: [ :index, :create, :update ]
      before_action :set_schedule, only: [ :update ]

      # GET /api/v1/recurring_schedules
      def index
        schedules = current_company.recurring_schedules.includes(:activity, :coach).order(:starts_on)
        render json: { recurring_schedules: schedules.map { |s| RecurringScheduleSerializer.new(s).as_json } }
      end

      # POST /api/v1/recurring_schedules
      def create
        activity = current_company.activities
                            .find_by(id: schedule_params[:activity_id])
        return render json: { error: "Activity not found" }, status: :not_found if activity.nil?

        schedule = current_company.recurring_schedules.new(schedule_params)

        if schedule.save
          generation = schedule.generate_sessions!
          render json: {
            recurring_schedule: RecurringScheduleSerializer.new(schedule.reload).as_json,
            **generation
          }, status: :created
        else
          render_errors(schedule)
        end
      end

      # PATCH /api/v1/recurring_schedules/:id — { active: false } stops a
      # series (RecurringSchedule#stop!); changing the pattern itself means
      # creating a new schedule, so generated sessions never silently shift.
      def update
        active = params.key?(:active) ? params[:active] : params.dig(:recurring_schedule, :active)
        unless ActiveModel::Type::Boolean.new.cast(active) == false
          return render json: { error: "Only stopping a series is supported", errors: [ "Only stopping a series is supported" ] },
                        status: :unprocessable_content
        end

        outcome = @schedule.stop!
        render json: { recurring_schedule: RecurringScheduleSerializer.new(@schedule).as_json, **outcome }
      end

      private

      def set_schedule
        @schedule = current_company.recurring_schedules.find(params[:id])
      end

      def schedule_params
        params.require(:recurring_schedule).permit(:activity_id, :coach_id, :start_time, :recurrence_type, :starts_on, :ends_on, weekdays: [])
      end
    end
  end
end
