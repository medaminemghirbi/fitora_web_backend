module Api
  module V1
    module Superadmin
      class CompaniesController < BaseController
        before_action :require_superadmin!
        before_action :set_company, only: [ :show, :update_subscription, :update_settings, :impersonate, :invoices, :create_invoice, :destroy_invoice ]

        # GET /api/v1/superadmin/companies?q=&closed=1
        #
        # `closed` narrows to the gyms whose access is shut. The count comes
        # back either way, so the list says how many without a screen of its
        # own — nobody should have to open a gym's page to find out. Access
        # is the account's, so every salle of a closed account is closed.
        def index
          companies = Company.includes(admin: [ :companies, { subscription: :invoices } ]).search(params[:q])
          closed = companies.joins(admin: :subscription).where(subscriptions: { active: false })

          only_closed = ActiveModel::Type::Boolean.new.cast(params[:closed])
          scope = (only_closed ? closed : companies).reorder(:name)

          render json: {
            companies: paginate(scope).map { |o| SuperadminCompanySerializer.new(o).as_json },
            meta: pagination_meta(scope),
            closed_count: closed.count
          }
        end

        # GET /api/v1/superadmin/companies/:id
        def show
          render json: {
            company: SuperadminCompanySerializer.new(@company).as_json,
            currency_options: CurrencyCatalog.options,
            locale_options: Company::LOCALES
          }
        end

        # PATCH /api/v1/superadmin/companies/:id/subscription — the ACCOUNT's
        # subscription, reached through any one of its salles: whether the
        # door is open (for every salle at once), which plan it is on, and
        # whether an invoice covers one month or twelve. None of them ends a
        # trial: only an invoice does (#create_invoice).
        def update_subscription
          subscription = @company.subscription || @company.admin.build_subscription

          attrs = {}
          attrs[:active] = ActiveModel::Type::Boolean.new.cast(params[:active]) if params.key?(:active)
          attrs[:billing_period] = params[:billing_period].presence if params.key?(:billing_period)
          attrs[:plan] = params[:plan].presence if params.key?(:plan)
          was_active = subscription.active
          was_plan = subscription.plan

          if subscription.update(attrs)
            # Only a change of access is an access event. Picking what the
            # next invoice covers used to be logged as "access restored",
            # which is what the admin's feed then told them.
            action =
              if subscription.active != was_active
                subscription.active? ? "subscription.access_restored" : "subscription.access_suspended"
              elsif subscription.plan != was_plan then "subscription.plan_changed"
              else "subscription.billing_period_changed"
              end
            AuditLog.record!(
              company: @company, user: current_user, action: action,
              auditable: subscription,
              metadata: {
                from: was_active, to: subscription.active, billing_period: subscription.billing_period,
                plan_from: was_plan, plan: subscription.plan
              }
            )
            render json: { company: SuperadminCompanySerializer.new(@company.reload).as_json }
          else
            render_errors(subscription)
          end
        end

        # PATCH /api/v1/superadmin/companies/:id/settings — tenant-wide display
        # settings a Fitora superadmin controls on the company's behalf: the app
        # language and the billing/display currency. { company: { currency:,
        # locale: } }.
        def update_settings
          if @company.update(company_settings_params)
            AuditLog.record!(
              company: @company, user: current_user, action: "superadmin.settings_updated",
              auditable: @company, metadata: { currency: @company.currency, locale: @company.locale }
            )
            render json: { company: SuperadminCompanySerializer.new(@company).as_json }
          else
            render_errors(@company)
          end
        end

        # POST /api/v1/superadmin/companies/:id/impersonate — issues a real
        # login session for the company's admin, marked with this
        # superadmin's id so it's traceable, and reuses the entire admin-facing
        # app as-is instead of duplicating every page for superadmin use.
        def impersonate
          admin = @company.admin
          return render json: { error: "This company has no admin account" }, status: :unprocessable_content if admin.nil?

          AuditLog.record!(
            company: @company, user: admin, action: "superadmin.impersonation_started",
            auditable: @company, metadata: { superadmin_id: current_user.id, superadmin_email: current_user.email }
          )

          render json: { token: JwtService.for_user(admin, impersonator: current_user), user: UserSerializer.new(admin).as_json }
        end

        # GET /api/v1/superadmin/companies/:id/invoices — the account's.
        def invoices
          scope = @company.subscription&.invoices || Invoice.none
          render json: {
            invoices: scope.newest_first.map { |i| InvoiceSerializer.new(i).as_json }
          }
        end

        # POST /api/v1/superadmin/companies/:id/invoices — the money arrived.
        #
        # Issues one invoice for the next period the account has not paid
        # for, at its plan's price, and opens access again for every salle.
        # Payment happens off-app, so this is the only record that it
        # happened at all.
        def create_invoice
          subscription = @company.subscription
          return render_errors("This gym has no subscription.") if subscription.nil?

          invoice = subscription.issue_invoice!(issued_by: current_user, notes: params[:notes].presence)
          AuditLog.record!(
            company: @company, user: current_user, action: "subscription.invoice_issued",
            auditable: invoice,
            metadata: { number: invoice.number, period_end: invoice.period_end, amount_cents: invoice.amount_cents }
          )
          Notification.push(
            recipient: @company.admin, kind: "invoice_issued",
            data: { number: invoice.number, amount: invoice.amount, currency: invoice.currency },
            url: "/admin/subscription", dedup_key: "invoice-#{invoice.id}"
          )
          render json: {
            invoice: InvoiceSerializer.new(invoice).as_json,
            company: SuperadminCompanySerializer.new(@company.reload).as_json
          }, status: :created
        end

        # DELETE /api/v1/superadmin/companies/:id/invoices/:invoice_id — an
        # invoice issued in error. Deleting it takes the coverage back with
        # it; the sweep closes access again if that leaves the account
        # uncovered.
        def destroy_invoice
          invoice = (@company.subscription&.invoices || Invoice.none).find(params[:invoice_id])
          number = invoice.number
          invoice.destroy!

          AuditLog.record!(
            company: @company, user: current_user, action: "subscription.invoice_voided",
            auditable: @company, metadata: { number: number }
          )
          render json: { company: SuperadminCompanySerializer.new(@company.reload).as_json }
        end

        private

        def set_company
          @company = Company.find(params[:id])
        end

        def company_settings_params
          params.require(:company).permit(:currency, :locale)
        end
      end
    end
  end
end
