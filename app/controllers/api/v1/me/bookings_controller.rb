module Api
  module V1
    module Me
      # A client's own bookings, from their own mobile login
      # (current_client — see ApplicationController). Deliberately its own
      # namespace rather than Api::V1::BookingsController: that one is
      # staff/admin-facing (current_user, current_company) and a bare
      # `Client` constant would resolve to this module inside a
      # `module Client`, so "me" avoids the collision entirely.
      class BookingsController < BaseController
        before_action :require_client!
        before_action :require_member_app!
        before_action :require_member_company!
        before_action :set_booking, only: [ :cancel ]

        # GET /api/v1/me/bookings?when=upcoming|past&company_id=
        def index
          upcoming = params[:when] != "past"
          scope = current_client.bookings.joins(:session)
                                 .where(sessions: { company_id: member_company ? [ member_company.id ] : member_companies.map(&:id) })
                                 .where(upcoming ? "sessions.starts_at >= ?" : "sessions.starts_at < ?", Time.current)
                                 .order("sessions.starts_at #{upcoming ? 'asc' : 'desc'}")

          render json: { bookings: scope.map { |b| BookingSerializer.new(b).as_json } }
        end

        # POST /api/v1/me/bookings { session_id: }
        def create
          # Bookable at any gym the person has joined whose app they can
          # use — and nowhere else.
          session = ::Session.where(company_id: member_companies.map(&:id)) # rubocop:disable Gymly/UnscopedTenantQuery
                              .find_by(id: params[:session_id])
          return render(json: { error: "Session not found" }, status: :not_found) if session.nil?

          result = Bookings::Create.call(client: current_client, session: session, by: :member)

          if result.success?
            render json: { booking: BookingSerializer.new(result.booking).as_json, waitlisted: result.waitlisted },
                   status: :created
          else
            render json: { error: result.error }, status: :unprocessable_content
          end
        end

        # POST /api/v1/me/bookings/:id/cancel
        def cancel
          result = Bookings::Cancel.call(booking: @booking, by: :member)

          if result.success?
            render json: { booking: BookingSerializer.new(@booking.reload).as_json }
          else
            render json: { error: result.error }, status: :unprocessable_content
          end
        end

        private

        def set_booking
          @booking = current_client.bookings.joins(:session)
                                   .where(sessions: { company_id: member_companies.map(&:id) })
                                   .find(params[:id])
        end
      end
    end
  end
end
