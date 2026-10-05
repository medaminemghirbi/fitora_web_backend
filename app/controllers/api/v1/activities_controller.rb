module Api
  module V1
    class ActivitiesController < BaseController
      before_action :require_company!
      before_action -> { require_schedule_reference_read!(:activities) }, only: [ :index, :show ]
      before_action -> { require_capability!(:activities) }, only: [ :create, :adopt, :update, :destroy ]
      before_action :set_activity, only: [ :show, :update, :destroy ]

      # GET /api/v1/activities
      def index
        scope = current_company.activities
        render json: { activities: scope.order(:name).map { |a| ActivitySerializer.new(a).as_json } }
      end

      # GET /api/v1/activities/:id
      def show
        render json: { activity: ActivitySerializer.new(@activity).as_json }
      end

      # POST /api/v1/activities — always attaches to the company's one location
      def create
        activity = current_company.activities.new(activity_params)

        if activity.save
          render json: { activity: ActivitySerializer.new(activity).as_json }, status: :created
        else
          render_errors(activity)
        end
      end

      # POST /api/v1/activities/adopt — { activity_template_ids: [] }: adds
      # activities from the catalogue, each a copy the salle then owns.
      def adopt
        created = current_company.adopt_activities!(template_ids: params[:activity_template_ids])
        render json: { activities: created.map { |a| ActivitySerializer.new(a).as_json } }, status: :created
      end

      # PATCH /api/v1/activities/:id
      def update
        if @activity.update(activity_params)
          render json: { activity: ActivitySerializer.new(@activity).as_json }
        else
          render_errors(@activity)
        end
      end

      # DELETE /api/v1/activities/:id — soft deactivate
      def destroy
        @activity.update!(active: false)
        render json: { activity: ActivitySerializer.new(@activity).as_json }
      end

      private

      def set_activity
        @activity = current_company.activities
                             .find(params[:id])
      end

      def activity_params
        params.require(:activity).permit(
          :name, :emoji, :description, :session_format, :duration, :capacity, :active
        )
      end
    end
  end
end
