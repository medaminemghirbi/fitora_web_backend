module Api
  module V1
    class CompaniesController < BaseController
      # A staff login posted to several salles lists and switches between
      # them too; everything else here is the admin's.
      before_action :require_admin!, except: [ :index, :switch ]
      before_action :set_workplace, only: [ :switch ]
      before_action :set_owned_company, only: [ :update_moderators ]
      # Several salles — the "Mes salles" page, its moderators, and moving
      # between salles — are Pro's. Starter and the free trial run one.
      before_action :require_pro!, only: [ :network, :update_moderators, :switch ]

      # GET /api/v1/company — the admin's currently ACTIVE company (see
      # #switch). Everything else in the API (current_company) follows
      # whichever one this is.
      def show
        render json: { company: CompanySerializer.new(current_company).as_json }
      end

      # GET /api/v1/companies — every salle this login can switch between
      # (User#workplaces), for the navbar switcher. Order is oldest-first
      # (predictable, matches signup order) rather than alphabetical, which
      # would reorder itself as they rename one.
      def index
        companies = current_user.workplaces.order(:created_at)
        render json: {
          companies: companies.map { |c| CompanySummarySerializer.new(c, active: c.id == current_company&.id).as_json }
        }
      end

      # GET /api/v1/companies/network — the admin's "Mes salles" page: every
      # salle with what it holds, and every moderator with where they work.
      def network
        render json: network_json
      end

      # POST /api/v1/companies — the admin's first salle, or another under
      # the same login: on a paid Pro account as many as they like, at one
      # price however many salles it covers; Starter runs one. Becomes the
      # active company immediately.
      def create
        unless current_user.may_open_salle?
          return render json: {
            error: "multi_salle_not_included",
            message: "Several salles come with Fitora Pro."
          }, status: :forbidden
        end

        company = Company.open!(admin: current_user, attributes: company_params,
                                activity_template_ids: params[:activity_template_ids],
                                custom_activities: custom_activities_param)
        render json: { company: CompanySerializer.new(company).as_json }, status: :created
      end

      # PATCH /api/v1/company
      def update
        require_company!
        return if performed?

        # currency + locale are tenant-wide settings a Fitora superadmin manages
        # (Api::V1::Superadmin::CompaniesController#update_settings); the admin
        # only picks a currency once, at signup.
        # A signature is taken off with remove_signature, never by sending
        # an empty file.
        current_company.signature.purge if ActiveModel::Type::Boolean.new.cast(params.dig(:company, :remove_signature))

        # Branding (logo, colour, identifier) is a Pro tool. On Starter it is
        # dropped rather than refused, so the rest of the form still saves.
        attrs = company_params(branding: current_company.pro_features?).except(:currency)

        if current_company.update(attrs)
          render json: { company: CompanySerializer.new(current_company).as_json }
        else
          render_errors(current_company)
        end
      end

      # POST /api/v1/companies/:id/switch — moves the session to another of
      # this login's OWN salles: one the admin runs, or one the staff login
      # is posted to (set_workplace 404s on anything else, same as every
      # other tenant-scoped lookup).
      def switch
        current_user.switch_active_company!(@company)
        render json: { company: current_user.admin? ? CompanySerializer.new(@company).as_json : CompanySummarySerializer.new(@company, active: true).as_json }
      end

      # PUT /api/v1/companies/:id/moderators — { user_ids: [] }: exactly who
      # works at this salle among the admin's moderators. See
      # Company#post_moderators!.
      def update_moderators
        @company.post_moderators!(params[:user_ids], by: current_user)
        render json: network_json
      end

      private

      def set_workplace
        @company = current_user.workplaces.find(params[:id])
      end

      def set_owned_company
        @company = current_user.companies.find(params[:id])
      end

      def network_json
        companies = current_user.companies.order(:created_at).to_a
        posts = current_user.salle_staff_members.where(coach_id: nil).includes(:user, :assigned_role).to_a
        members = current_user.salle_memberships.where(active: true).group(:company_id).count

        {
          companies: companies.map do |company|
            CompanySummarySerializer.new(company, active: company.id == current_company&.id).as_json.merge(
              city: company.city,
              members_count: members.fetch(company.id, 0),
              moderator_ids: posts.select { |p| p.company_id == company.id }.map(&:user_id)
            )
          end,
          moderators: posts.group_by(&:user_id).map do |_, records|
            first = records.min_by(&:created_at)
            user = first.user
            {
              id: user.id,
              full_name: user.full_name,
              email: EmailMask.call(user.email),
              role_name: first.assigned_role.name,
              role_key: first.assigned_role.key,
              active: records.any?(&:active?),
              company_ids: records.map(&:company_id)
            }
          end.sort_by { |m| m[:full_name].downcase }
        }
      end

      # Activities the salle names itself at signup — [{ name:, emoji: }].
      def custom_activities_param
        params.fetch(:custom_activities, []).map { |entry| entry.permit(:name, :emoji) }
      end

      # branding: false leaves out the logo, the colour and the identifier —
      # Starter's update (see #update).
      def company_params(branding: true)
        permitted = params.require(:company).permit(
          :name, :description, :phone, :email, :country, :city,
          :address, :latitude, :longitude, :timezone, :currency,
          :slug, :logo,
          # Who signs the gym's contracts, and what they print (Settings).
          :signature, :signatory_name, :contract_terms,
          # Hours and branding are settings now, but the app still sends them
          # flat. Accept them where they have always been and fold them in.
          :primary_color, :business_hours_start, :business_hours_end,
          working_days: [],
          settings: [
            { features: CompanySettings::FEATURES.keys },
            { booking: CompanySettings::BOOKING.keys },
            { hours: [ :start, :end, { working_days: [] } ] },
            { branding: CompanySettings::BRANDING.keys }
          ]
        )

        unless branding
          permitted = permitted.except(:slug, :logo, :primary_color)
          permitted[:settings] = permitted[:settings].except(:branding) if permitted[:settings]
        end

        fold_legacy_settings_keys(permitted)
      end

      # Moves the flat hours/branding keys into the settings patch, so the
      # model sees one shape whichever way the client sent them. An explicit
      # `settings` section wins over the flat key for the same value.
      def fold_legacy_settings_keys(permitted)
        hours = {
          start: permitted.delete(:business_hours_start),
          end: permitted.delete(:business_hours_end),
          working_days: permitted.delete(:working_days)
        }.compact
        branding = { primary_color: permitted.delete(:primary_color) }.compact

        return permitted if hours.empty? && branding.empty?

        settings = (permitted[:settings] || {}).to_h.symbolize_keys
        settings[:hours] = hours.merge((settings[:hours] || {}).to_h.symbolize_keys)
        settings[:branding] = branding.merge((settings[:branding] || {}).to_h.symbolize_keys)
        permitted[:settings] = settings
        permitted
      end
    end
  end
end
