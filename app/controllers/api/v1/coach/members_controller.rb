module Api
  module V1
    module Coach
      # The people a coach actually trains: everyone with a live booking on
      # one of their own sessions.
      #
      # This is the one thing the coach's day needed that no existing endpoint
      # answered. The schedule and attendance endpoints already narrow to a
      # coach's own sessions (SessionsController#base_scope,
      # AttendanceController#accessible_sessions), so there is deliberately no
      # parallel /coach/sessions here — a second way to ask the same question
      # is a second place for the narrowing to be got wrong.
      #
      # A coach sees a member's name, how to reach them, and when they last
      # came or next will. Not their subscription, not their balance, not what
      # they have paid — none of that is a coach's business, and it is absent
      # from the response rather than merely unused by the UI. Their
      # contraindications ARE the coach's business: an EMS suit or a reformer
      # is not something to put someone with a pacemaker or a recent injury
      # on without knowing.
      class MembersController < BaseController
        before_action :require_company!
        before_action :require_coach!

        # GET /api/v1/coach/members?q=
        def index
          scope = members.merge(::Client.search(params[:q]))
          total = scope.count

          page = paginate(scope.order(:first_name, :last_name)).to_a
          @health = current_company.memberships.where(client_id: page.map(&:id)).pluck(:client_id, :health_notes).to_h

          render json: {
            members: page.map { |client| serialize(client) },
            meta: pagination_meta(scope)
          }
        end

        private

        # Only this coach's own sessions, and only bookings that still stand —
        # a cancelled booking does not make someone your member.
        def my_sessions
          current_company.sessions.where(coach_id: current_staff_member.coach_id)
        end

        def members
          current_company.clients
                         .joins(bookings: :session)
                         .where(sessions: { id: my_sessions.select(:id) })
                         .where.not(bookings: { status: :cancelled })
                         .distinct
        end

        def serialize(client)
          {
            id: client.id,
            full_name: client.full_name,
            phone: client.phone,
            email: EmailMask.call(client.email),
            health_notes: @health[client.id].presence,
            last_seen_at: last_seen_at(client),
            next_session_at: next_session_at(client)
          }
        end

        def last_seen_at(client)
          my_sessions.joins(:bookings)
                     .where(bookings: { client_id: client.id })
                     .where.not(bookings: { status: :cancelled })
                     .where(starts_at: ..Time.current)
                     .maximum(:starts_at)
        end

        def next_session_at(client)
          my_sessions.joins(:bookings)
                     .where(bookings: { client_id: client.id })
                     .where.not(bookings: { status: :cancelled })
                     .where(starts_at: Time.current..)
                     .minimum(:starts_at)
        end

        # Not a capability check: this endpoint is only meaningful for someone
        # who has sessions of their own. Anyone else asking gets nothing,
        # because there is nothing there to give them.
        def require_coach!
          render_forbidden unless current_staff_member&.active? && current_staff_member.coach?
        end
      end
    end
  end
end
