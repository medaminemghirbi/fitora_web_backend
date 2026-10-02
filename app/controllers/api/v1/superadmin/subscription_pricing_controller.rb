module Api
  module V1
    module Superadmin
      # What each plan (Starter, Pro) costs per month in each currency, plus
      # the global annual-billing discount. Superadmin-only. Prices are
      # informational — payment happens outside the app.
      class SubscriptionPricingController < BaseController
        before_action :require_superadmin!

        # GET /api/v1/superadmin/subscription_pricing?currency=EUR — both
        # plans for one currency at once (defaults to
        # SubscriptionPrice::REFERENCE_CURRENCY, TND, when omitted).
        def show
          currency = params[:currency].presence || SubscriptionPrice::REFERENCE_CURRENCY
          render json: pricing_json(currency)
        end

        # PATCH /api/v1/superadmin/subscription_pricing?currency=EUR
        #   { plans: { "starter" => monthly_cents, "pro" => ... }, annual_discount_percent? }
        # Either plan may be sent alone — an omitted one is left as-is.
        def update
          currency = params[:currency].presence || SubscriptionPrice::REFERENCE_CURRENCY
          setting = PlatformSetting.current
          setting.annual_discount_percent = params[:annual_discount_percent] if params.key?(:annual_discount_percent)

          plans = params[:plans].present? ? params[:plans].permit(*SubscriptionPrice::PLANS).to_h : {}
          rows = plans.map do |plan, monthly_cents|
            price = SubscriptionPrice.for(currency, plan: plan)
            price.monthly_cents = monthly_cents
            price
          end

          if rows.all?(&:valid?) && setting.valid?
            ActiveRecord::Base.transaction do
              rows.each(&:save!)
              setting.save!
            end
            render json: pricing_json(currency)
          else
            errors = rows.flat_map { |r| r.errors.full_messages } + setting.errors.full_messages
            render json: { error: errors.first, errors: errors }, status: :unprocessable_content
          end
        end

        private

        def pricing_json(currency)
          discount = PlatformSetting.current.annual_discount_percent

          plans = SubscriptionPrice::PLANS.map do |plan|
            price = SubscriptionPrice.for(currency, plan: plan)
            {
              plan: plan,
              monthly_cents: price.monthly_cents,
              annual_cents: price.annual_cents(discount),
              # How many accounts this price is charged to today.
              accounts_count: accounts_on(plan, currency)
            }
          end

          {
            currencies: CurrencyCatalog::CODES,
            currency: currency,
            annual_discount_percent: discount,
            plans: plans,
            companies_count: Company.where(currency: currency).count
          }
        end

        # An account pays in its first salle's currency (Subscription#currency).
        def accounts_on(plan, currency)
          Subscription.where(plan: plan).includes(admin: :companies).count { |s| s.currency == currency }
        end
      end
    end
  end
end
