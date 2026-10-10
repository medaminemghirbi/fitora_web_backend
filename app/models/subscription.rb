# An admin's access to Fitora — one per account, covering every salle the
# admin runs, at one price however many there are.
#
# `active` IS the access: every check reads it, nothing computes a date at
# read time. It is set false by a Fitora superadmin suspending the account,
# and by the nightly sweep once the last invoice's period has run out and the
# three days of grace with it (Subscription.close_unpaid!). Issuing an
# invoice sets it back to true.
#
# Everything else about paying lives in the invoices: "paid until" is the
# latest period_end, arrears are the periods with no invoice. The free trial
# is the first period, given away: an invoice like any other, flagged
# `trial` so the account is shown as trying Fitora rather than as already on
# a plan it never chose.
#
# A trial account has NO plan and no billing period — nil, not a default.
# The superadmin picks both when the first payment is set up, and no
# invoice can be issued before a plan is chosen. Once an account has paid,
# it always has a plan.
class Subscription < ApplicationRecord
  belongs_to :admin, class_name: "User", inverse_of: :subscription
  has_many :invoices, dependent: :destroy

  BILLING_PERIODS = { monthly: 0, yearly: 1 }.freeze

  # The two plans Fitora sells. Starter is the whole product for one salle;
  # Pro adds several salles, the member app, and every update Fitora ships.
  PLANS = { starter: "starter", pro: "pro" }.freeze

  # How long a gym has to settle once the period it paid for has run out,
  # before access closes. Three days catches a transfer that crossed a
  # weekend, and is short enough not to be a free extra month.
  GRACE_DAYS = 3

  # What signup gives away: the whole product, member app included.
  TRIAL_DAYS = 14

  # Explicit attribute so the enum resolves even when the dev server's code
  # reloader runs before the schema cache has picked up the new column.
  attribute :billing_period, :integer
  enum :billing_period, BILLING_PERIODS
  attribute :plan, :string
  enum :plan, PLANS, validate: { allow_nil: true }

  validates :admin_id, uniqueness: true
  # Nil is the trial's "nothing chosen yet" — never a paid account's.
  validates :plan, presence: true, if: :ever_paid?

  # Raised by #issue_invoice! while no plan is chosen: there is no price to
  # put on the invoice.
  class PlanNotChosen < StandardError; end

  scope :closed, -> { where(active: false) }

  # Opens an admin's account with the free trial: the first period given
  # away as an invoice like any other, flagged `trial` so the account reads
  # as trying Fitora rather than as on a plan it never chose. Access is open
  # because the trial invoice covers today.
  def self.start_trial!(admin, currency:)
    # No plan, no billing period: the trial is all the account is on.
    subscription = admin.create_subscription!(active: true, plan: nil, billing_period: nil)
    subscription.invoices.create!(
      number: Invoice.next_number,
      period_start: Date.current,
      period_end: Date.current + (TRIAL_DAYS - 1),
      amount_cents: 0,
      trial: true,
      plan: nil,
      currency: currency,
      # The column wants one; a free period is not billed on any.
      billing_period: :monthly,
      issued_at: Time.current,
      notes: "Période d'essai — #{TRIAL_DAYS} jours offerts"
    )
    subscription
  end

  # The nightly sweep: closes access for every account whose last invoice
  # ran out more than GRACE_DAYS ago — and with it, every salle it covers.
  # Returns how many were closed.
  #
  # Idempotent by design — it only ever moves `active` from true to false,
  # and an account already closed is skipped. Running it twice, or missing a
  # night and running it late, changes nothing about the outcome.
  def self.close_unpaid!
    closed = 0

    where(active: true).includes(:invoices, admin: :companies).find_each do |subscription|
      # "Ran out more than three days ago" is counted in the gym's days.
      next unless Time.use_zone(subscription.time_zone) { subscription.uncovered? }

      subscription.update!(active: false)
      closed += 1
    end

    closed
  end

  # The salle the account is billed through: its first. Its name and address
  # head the invoices, and its currency is the one the account pays in.
  def billing_company
    admin.companies.min_by(&:created_at)
  end

  def currency
    billing_company&.currency || SubscriptionPrice::REFERENCE_CURRENCY
  end

  # "Today" for the account is today at its first salle.
  def time_zone
    billing_company&.time_zone || Time.zone
  end

  # Everything Pro sells beyond running one salle: several salles and
  # switching between them, the member app, custom roles & permissions, the
  # gym's own branding (logo, colour, identifier) and CSV import / export.
  #
  # Only a PAID Pro period opens them. The free trial is Starter-level —
  # every Pro feature stays locked until Pro is bought — and picking Pro
  # during the trial does not unlock anything before the payment lands.
  def pro_features?
    pro? && !trial?
  end

  # Whether members may sign in to their own app: a Pro feature, locked
  # during the free trial.
  def member_app?
    pro_features?
  end

  # Whether the account may open another salle. Starter — and the free
  # trial — run one; a paid Pro account runs as many as the admin likes
  # (User#may_open_salle?).
  def multi_salle?
    pro_features?
  end

  # ---- what the invoices say ----------------------------------------------

  def latest_invoice
    invoices.newest_first.first
  end

  # The last day covered by an invoice, or nil when none was ever issued.
  def paid_through
    latest_invoice&.period_end
  end

  def current_period_paid?
    paid_through.present? && paid_through >= Date.current
  end

  # Nothing has been paid yet: the last period on record is the free one,
  # running or run out.
  def trial?
    latest_invoice&.trial? || false
  end

  # Free days left, today included. nil outside a trial.
  def trial_days_left
    return nil unless trial?

    [ (paid_through - Date.current).to_i + 1, 0 ].max
  end

  # The grace is for a payment in flight. A trial has none, so it closes the
  # day after it ends.
  def grace_days
    trial? ? 0 : GRACE_DAYS
  end

  # Past the paid period AND past the grace. What the nightly sweep acts on.
  def uncovered?
    paid_through.nil? || Date.current > paid_through + grace_days
  end

  # Days left before the sweep closes access. nil when nothing is ticking.
  def days_before_lock
    return nil if current_period_paid? || paid_through.nil?

    [ (paid_through + grace_days - Date.current).to_i, 0 ].max
  end

  # ---- why the door is shut, in two words ---------------------------------
  # Suspended is a decision; unpaid is everything else. An expired trial is
  # unpaid too — `trial?` is what lets a screen word it as the end of the
  # free days rather than a missed payment.
  def lock_reason
    return nil if active?

    uncovered? ? :unpaid : :suspended
  end

  def locked?
    !active?
  end

  # The period an invoice would cover next: the day after the last one ends,
  # or today when there is no history. A first payment after the trial ran
  # out starts today — the days in between were closed, not owed.
  def next_period
    start = paid_through ? paid_through.next_day : Date.current
    start = [ start, Date.current ].max if trial?
    finish = yearly? ? ((start >> 12) - 1) : ((start >> 1) - 1)
    start..finish
  end

  # Periods with no invoice behind them, times the tariff. Replaces the
  # figure that used to be typed in by hand and could contradict the history
  # beside it.
  def arrears_cents
    return 0 if current_period_paid?
    # A trial that ran out was never a promise to pay.
    return 0 if trial?

    # Never invoiced at all: the period in progress is owed. Reporting zero
    # here read as "nothing due" right beside "paid through: never".
    return period_cents if paid_through.nil?

    months = ((Date.current.year * 12 + Date.current.month) - (paid_through.year * 12 + paid_through.month))
    periods = yearly? ? (months / 12.0).ceil : months
    [ periods, 1 ].max * period_cents
  end

  # The plan's tariff in the account's currency. nil while no plan is
  # chosen (the trial) — and so are the three amounts below.
  def price
    plan && SubscriptionPrice.for(currency, plan: plan)
  end

  def monthly_cents = price&.monthly_cents
  def annual_cents = price&.annual_cents

  def period_cents
    yearly? ? annual_cents : monthly_cents
  end

  # Whether any period was ever paid for (the trial's free one aside).
  def ever_paid?
    persisted? && invoices.where(trial: false).exists?
  end

  # Records that money arrived: one invoice for the next period the account
  # has not paid for, at its plan's price, and access opened again for every
  # salle it covers. Returns the invoice.
  #
  # The amount is frozen here, at the tariff of the day. A price change later
  # must never rewrite a past invoice — the same rule Contract#base_price
  # follows for a member's own subscription.
  def issue_invoice!(issued_by:, notes: nil)
    raise PlanNotChosen, "Choose a plan before recording a payment." if plan.nil?

    period = next_period

    transaction do
      invoice = invoices.create!(
        number: Invoice.next_number,
        period_start: period.first,
        period_end: period.last,
        amount_cents: period_cents,
        plan: plan,
        currency: currency,
        billing_period: billing_period || :monthly,
        issued_at: Time.current,
        issued_by: issued_by,
        notes: notes
      )

      # Paying is what reopens the door; there is nothing else to do.
      update!(active: true)
      invoice
    end
  end

  def suspend!
    update!(active: false)
  end

  def restore!
    update!(active: true)
  end
end
