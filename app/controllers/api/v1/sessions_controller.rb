module Api
  module V1
    class SessionsController < BaseController
      before_action :require_company!
      before_action :require_staff!, only: [ :index, :show, :schedule_pdf ]
      before_action :require_session_management!, only: [ :create, :update, :cancel ]
      before_action :set_session, only: [ :show, :update, :cancel ]

      # GET /api/v1/sessions?activity_id=&coach_id=&date=&status=
      # GET /api/v1/sessions?from=&to=&... — range query, used by the calendar
      def index
        scope = base_scope
        scope = scope.where(activity_id: params[:activity_id]) if params[:activity_id].present?
        scope = scope.where(coach_id: params[:coach_id]) if params[:coach_id].present?
        scope = scope.where(status: params[:status]) if params[:status].present?
        scope = scope.for_date(Date.parse(params[:date])) if params[:date].present?
        scope = scope.includes(:activity, :company, :coach).order(:starts_at)

        # The calendar asks for a bounded date range and needs every session
        # in it, not a paginated slice — pagination only applies to the
        # unbounded list view.
        if params[:from].present? && params[:to].present?
          scope = scope.where(starts_at: Date.parse(params[:from]).beginning_of_day..Date.parse(params[:to]).end_of_day)
          render json: { sessions: serialize_sessions(scope.to_a) }
        else
          render json: {
            sessions: serialize_sessions(paginate(scope).to_a),
            meta: pagination_meta(scope)
          }
        end
      end

      # GET /api/v1/sessions/:id
      def show
        render json: { session: SessionSerializer.new(@session).as_json }
      end

      # GET /api/v1/sessions/schedule_pdf?from=
      # Prints the week containing `from` (defaults to today), one page per
      # coach. `base_scope` already keeps a coach login to their own sessions.
      def schedule_pdf
        week_start = (params[:from].present? ? Date.parse(params[:from]) : Date.current).beginning_of_week(:monday)
        week_end = week_start + 6.days

        scope = base_scope.where(starts_at: week_start.beginning_of_day..week_end.end_of_day)
        sessions = scope.includes(:activity, :coach).order(:starts_at)


        pdf = Schedule::WeeklyPdf.call(company: current_company, week_start: week_start, sessions: sessions)
        send_data pdf, filename: "planning-#{week_start.strftime('%Y-%m-%d')}.pdf", type: "application/pdf", disposition: "inline"
      end

      # POST /api/v1/sessions
      def create
        activity = current_company.activities
                            .find_by(id: session_params[:activity_id])
        return render json: { error: "Activity not found" }, status: :not_found if activity.nil?

        client_id = params.require(:session).permit(:client_id)[:client_id]
        client = client_id.present? ? current_company.clients.find_by(id: client_id) : nil
        return render json: { error: "Client not found" }, status: :not_found if client_id.present? && client.nil?

        # The activity's capacity unless one is given. No activity-level
        # price to fall back to — booking is settled against the member's
        # contract — so a blank price leaves the column default (0).
        attributes = session_params.to_h.symbolize_keys
        attributes[:capacity] = attributes[:capacity].presence || activity.capacity
        attributes.delete(:price) if attributes[:price].blank?
        session = current_company.sessions.new(attributes)

        # An individual session is scheduled *for* one member, who is booked
        # into it in the same transaction: if the booking cannot go through,
        # the session never existed.
        ActiveRecord::Base.transaction do
          session.save!
          session.book!(client) if client
        end

        render json: { session: SessionSerializer.new(session).as_json }, status: :created
      end

      # PATCH /api/v1/sessions/:id
      def update
        if @session.update(session_params)
          render json: { session: SessionSerializer.new(@session).as_json }
        else
          render_errors(@session)
        end
      end

      # POST /api/v1/sessions/:id/cancel
      def cancel
        cancelled = @session.cancel!
        AuditLog.record!(
          company: current_company, user: current_user, action: "session.cancelled",
          auditable: @session,
          metadata: { activity: @session.activity.name, starts_at: @session.starts_at, bookings_cancelled: cancelled }
        )
        render json: { session: SessionSerializer.new(@session).as_json, bookings_cancelled: cancelled }
      end

      private

      def serialize_sessions(sessions)
        counts = SessionSerializer.confirmed_counts(sessions)
        sessions.map { |s| SessionSerializer.new(s, confirmed_count: counts.fetch(s.id, 0)).as_json }
      end

      # Coach-role staff only ever see/touch their own sessions; everyone
      # else with the `sessions` capability sees the whole company.
      def base_scope
        scope = current_company.sessions
        current_staff_member&.coach? ? scope.where(coach_id: current_staff_member.coach_id) : scope
      end

      # Creating/editing/cancelling sessions is an operational (admin/superadmin/
      # manager) task — coaches can view their schedule but not restructure it.
      def require_session_management!
        return if current_user.admin?
        return if current_staff_member&.active? && current_staff_member.can?(:sessions) && !current_staff_member.coach?

        render_forbidden
      end

      def set_session
        @session = base_scope.find(params[:id])
      end

      def session_params
        params.require(:session).permit(:activity_id, :coach_id, :space_id, :starts_at, :ends_at, :capacity, :price, :status)
      end
    end
  end
end
