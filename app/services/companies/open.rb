module Companies
  # A salle opening on Gymly: the company and its built-in roles. The
  # admin's first salle also opens the account — its subscription and the
  # free trial, the first period given away as an invoice like any other,
  # flagged so the account reads as trying Gymly rather than as on a plan it
  # never chose. A later salle joins the account it already has: same plan,
  # same price, no second trial — and only on an account that runs several
  # (Subscription#multi_salle?: Pro, or the trial). The admin's session
  # moves onto it.
  class Open
    Result = ServiceResult.define(:company)

    MULTI_SALLE_NOT_INCLUDED = "multi_salle_not_included"

    def self.call(admin:, attributes:) = new(admin: admin, attributes: attributes).call

    def initialize(admin:, attributes:)
      @admin = admin
      @attributes = attributes
    end

    def call
      return Result.failure(MULTI_SALLE_NOT_INCLUDED) unless may_open?

      company = Company.new(attributes)
      company.admin = admin

      ActiveRecord::Base.transaction do
        company.save!
        # Built-in roles (admin, moderator, coach) — a company can
        # re-permission them or add its own from Settings.
        Role.seed_defaults_for(company)
        open_account(company) if admin.subscription.nil?
        admin.update!(active_company: company)
      end

      Result.ok(company: company)
    rescue ActiveRecord::RecordInvalid => e
      Result.failure(e.record.errors.full_messages.first, company: company)
    end

    private

    attr_reader :admin, :attributes

    # The first salle always opens; another needs an account that runs
    # several. No subscription beside an existing salle is no plan at all.
    def may_open?
      !admin.companies.exists? || admin.subscription&.multi_salle? || false
    end

    # Access is open because the trial invoice covers today.
    def open_account(company)
      subscription = admin.create_subscription!(active: true, billing_period: :monthly, plan: :starter)
      subscription.invoices.create!(
        number: Invoice.next_number,
        period_start: Date.current,
        period_end: Date.current + (Subscription::TRIAL_DAYS - 1),
        amount_cents: 0,
        trial: true,
        plan: subscription.plan,
        currency: company.currency,
        billing_period: subscription.billing_period,
        issued_at: Time.current,
        notes: "Période d'essai — #{Subscription::TRIAL_DAYS} jours offerts"
      )
    end
  end
end
