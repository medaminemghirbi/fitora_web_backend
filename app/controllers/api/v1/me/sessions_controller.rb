module Api
  module V1
    module Me
      # The schedule of the gym the member belongs to — what their app opens
      # on. Read-only: booking is Me::BookingsController#create.
      #
      # Sessions are serialised through PublicSessionSerializer, which says
      # how many places are left and never what the gym charges or who else
      # is coming.
      class SessionsController < BaseController
        before_action :require_client!
        before_action :require_member_app!
        before_action :require_member_company!

        # GET /api/v1/me/sessions?date=YYYY-MM-DD&company_id=
        def index
          company_ids = member_company ? [ member_company.id ] : member_companies.map(&:id)
          # The scoping IS the tenancy check here: company_ids comes from the
          # client's own memberships, so a gym they have not joined cannot appear.
          scope = ::Session.where(company_id: company_ids) # rubocop:disable Fitora/UnscopedTenantQuery
                            .where(status: :scheduled)
                            .upcoming
                            .order(:starts_at)
          scope = scope.for_date(Date.parse(params[:date])) if params[:date].present?
          scope = scope.includes(:activity, :coach, :space)

          sessions = scope.map { |s| PublicSessionSerializer.new(s, current_client: current_client).as_json }
          # A one-to-one slot someone else has taken is not a session this
          # member could ever join — it is another person's appointment, and
          # listing it as "full" would only bury the free slots.
          sessions.reject! { |s| s[:individual] && s[:full] && !s[:already_booked] }

          render json: { sessions: sessions }
        end
      end
    end
  end
end
