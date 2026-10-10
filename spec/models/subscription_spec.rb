require "rails_helper"

RSpec.describe Subscription do
  let(:company) { create(:company) }

  def paid_until(date, period: :monthly)
    subscription = create(:subscription, company: company, billing_period: period)
    create(:invoice, company: company, period_start: date - 30, period_end: date, billing_period: period)
    subscription.reload
  end

  it "belongs to exactly one company" do
    create(:subscription, company: company)
    expect(build(:subscription, company: company)).not_to be_valid
  end

  describe "#active — the access itself" do
    it "is what locked? reads, with nothing computed" do
      expect(create(:subscription, company: company)).not_to be_locked
      expect(create(:subscription, :closed, company: create(:company))).to be_locked
    end

    it "suspends and restores" do
      subscription = create(:subscription, company: company)

      subscription.suspend!
      expect(subscription.reload).to be_locked

      subscription.restore!
      expect(subscription.reload).not_to be_locked
    end
  end

  describe "what the invoices say" do
    it "reads paid_through from the latest invoice" do
      subscription = paid_until(Date.new(2026, 9, 30))
      expect(subscription.paid_through).to eq(Date.new(2026, 9, 30))
    end

    it "has no paid_through at all before the first invoice" do
      subscription = create(:subscription, company: company)
      expect(subscription.paid_through).to be_nil
      expect(subscription).not_to be_current_period_paid
    end

    it "takes the latest period, not the last row created" do
      subscription = create(:subscription, company: company)
      create(:invoice, company: company, period_start: Date.current, period_end: Date.current + 20)
      create(:invoice, company: company, period_start: Date.current - 60, period_end: Date.current - 30)

      expect(subscription.reload.paid_through).to eq(Date.current + 20)
    end
  end

  describe "the three days to settle" do
    it "is not uncovered on the first day after the period ends" do
      subscription = paid_until(Date.current.prev_day)
      expect(subscription).not_to be_uncovered
      expect(subscription.days_before_lock).to eq(2)
    end

    it "is still not uncovered on the third day" do
      subscription = paid_until(Date.current - 3)
      expect(subscription).not_to be_uncovered
      expect(subscription.days_before_lock).to eq(0)
    end

    it "is uncovered on the fourth" do
      subscription = paid_until(Date.current - 4)
      expect(subscription).to be_uncovered
    end

    it "reports nothing ticking while the period is still paid" do
      expect(paid_until(Date.current.end_of_month).days_before_lock).to be_nil
    end

    it "treats a gym that never paid as uncovered" do
      expect(create(:subscription, company: company)).to be_uncovered
    end
  end

  describe "the free trial" do
    def trial_ending(date)
      subscription = create(:subscription, company: company)
      create(:invoice, :trial, company: company, period_start: date - (Subscription::TRIAL_DAYS - 1), period_end: date)
      subscription.reload
    end

    it "is on trial while the only invoice is the free one" do
      subscription = trial_ending(Date.current + 13)
      expect(subscription).to be_trial
      expect(subscription.trial_days_left).to eq(14)
    end

    it "counts the last free day as a day left" do
      expect(trial_ending(Date.current).trial_days_left).to eq(1)
    end

    it "is no longer on trial once a paid invoice follows it" do
      subscription = trial_ending(Date.current + 5)
      create(:invoice, company: company, period_start: Date.current + 6, period_end: Date.current + 36)

      expect(subscription.reload).not_to be_trial
      expect(subscription.trial_days_left).to be_nil
    end

    it "gets no grace: uncovered the day after it ends" do
      subscription = trial_ending(Date.current.prev_day)
      expect(subscription).to be_uncovered
      expect(subscription.days_before_lock).to eq(0)
    end

    it "owes nothing once it has run out" do
      expect(trial_ending(Date.current - 10).arrears_cents).to eq(0)
    end

    it "keeps the free days left when the first payment lands during the trial" do
      subscription = trial_ending(Date.current + 5)
      expect(subscription.next_period.first).to eq(Date.current + 6)
    end

    it "starts the first paid period today when the trial already ran out" do
      subscription = trial_ending(Date.current - 10)
      expect(subscription.next_period.first).to eq(Date.current)
    end

    it "is not a trial for a gym paying normally" do
      expect(paid_until(Date.current.end_of_month)).not_to be_trial
    end

    it "opens on nothing but the trial: no plan, no billing period" do
      subscription = described_class.start_trial!(company.admin, currency: "TND")

      expect(subscription).to be_trial
      expect(subscription.plan).to be_nil
      expect(subscription.billing_period).to be_nil
      expect(subscription.invoices.sole.plan).to be_nil
      # Nothing to price yet — and nothing crashes asking.
      expect(subscription.monthly_cents).to be_nil
      expect(subscription.arrears_cents).to eq(0)
      # The trial is Starter-level: every Pro feature stays locked.
      expect(subscription).not_to be_member_app
      expect(subscription).not_to be_multi_salle
      expect(subscription).not_to be_pro_features
    end

    it "issues no invoice before a plan is chosen" do
      subscription = described_class.start_trial!(company.admin, currency: "TND")

      expect { subscription.issue_invoice!(issued_by: nil) }.to raise_error(Subscription::PlanNotChosen)
      expect(subscription.invoices.count).to eq(1)
    end

    it "keeps a plan for good once the account has paid" do
      subscription = described_class.start_trial!(company.admin, currency: "TND")
      subscription.update!(plan: :pro)
      subscription.issue_invoice!(issued_by: nil)

      expect(subscription.update(plan: nil)).to be(false)
      expect(subscription.errors[:plan]).to be_present
    end
  end

  describe "#multi_salle? — opening another salle" do
    it "is Pro's" do
      expect(create(:subscription, :pro, company: company)).to be_multi_salle
    end

    it "is not Starter's" do
      expect(paid_until(Date.current.end_of_month)).not_to be_multi_salle
    end

    it "is locked on the free trial, like every Pro feature" do
      subscription = create(:subscription, company: company)
      create(:invoice, :trial, company: company, period_start: Date.current, period_end: Date.current + 13)

      expect(subscription.reload).not_to be_multi_salle
      expect(subscription).not_to be_member_app
      expect(subscription).not_to be_pro_features
    end

    it "stays locked when Pro is picked during the trial, until Pro is paid" do
      subscription = described_class.start_trial!(company.admin, currency: "TND")
      subscription.update!(plan: :pro)
      expect(subscription).not_to be_pro_features

      subscription.issue_invoice!(issued_by: nil)
      expect(subscription.reload).to be_pro_features
    end
  end

  describe "#lock_reason — two words, never four" do
    it "is nil while access is open" do
      expect(paid_until(Date.current.end_of_month).lock_reason).to be_nil
    end

    it "says unpaid when the invoices ran out" do
      subscription = paid_until(Date.current - 10)
      subscription.suspend!
      expect(subscription.lock_reason).to eq(:unpaid)
    end

    it "says suspended when a paid-up gym was closed by hand" do
      subscription = paid_until(Date.current.end_of_month)
      subscription.suspend!
      expect(subscription.lock_reason).to eq(:suspended)
    end
  end

  describe "#next_period — what an invoice would cover" do
    it "starts the day after the last one ended" do
      subscription = paid_until(Date.new(2026, 8, 31))
      expect(subscription.next_period).to eq(Date.new(2026, 9, 1)..Date.new(2026, 9, 30))
    end

    it "starts today for a gym with no history" do
      subscription = create(:subscription, company: company)
      expect(subscription.next_period.first).to eq(Date.current)
    end

    it "covers a year on a yearly plan" do
      subscription = paid_until(Date.new(2026, 12, 31), period: :yearly)
      expect(subscription.next_period).to eq(Date.new(2027, 1, 1)..Date.new(2027, 12, 31))
    end
  end

  describe "#arrears_cents — owed, never typed in" do
    it "is zero while the period is paid" do
      expect(paid_until(Date.current.end_of_month).arrears_cents).to eq(0)
    end

    it "counts the months with no invoice behind them" do
      subscription = paid_until(Date.current.prev_month.end_of_month)
      expect(subscription.arrears_cents).to eq(company.monthly_subscription_cents)
    end

    # Reporting zero here read as "nothing due" right beside "paid through:
    # never", which is the pair of figures a superadmin acts on.
    it "owes the period in progress when nothing was ever invoiced" do
      subscription = create(:subscription, company: company, billing_period: :monthly)
      expect(subscription.arrears_cents).to eq(company.monthly_subscription_cents)
    end

    it "owes a year at a time on a yearly plan" do
      other = create(:company)
      subscription = create(:subscription, company: other, billing_period: :yearly)
      expect(subscription.arrears_cents).to eq(other.annual_subscription_cents)
    end
  end
end
