require "rails_helper"

RSpec.describe CompanySettings do
  describe "defaults" do
    it "gives a company that has configured nothing a working set of rules" do
      settings = described_class.default

      expect(settings.feature?(:bookings)).to be(true)
      expect(settings.feature?(:spaces)).to be(false)
      expect(settings.feature?(:waitlist)).to be(false)
      expect(settings.cancellation_hours).to eq(2)
      expect(settings.booking_opens_days).to eq(14)
    end

    it "treats a nil or junk column as empty rather than blowing up" do
      expect(described_class.new(nil).feature?(:bookings)).to be(true)
      expect(described_class.new("nonsense").cancellation_hours).to eq(2)
    end

    it "is false for a feature that does not exist" do
      expect(described_class.default.feature?(:teleportation)).to be(false)
    end
  end

  describe "the closed surface" do
    it "drops keys it does not declare instead of storing them" do
      settings = described_class.new(
        features: { spaces: true, crypto_payments: true },
        booking: { cancellation_hours: 6, moon_phase: "waxing" },
        billing: { anything: 1 }
      )

      expect(settings.to_h[:features]).not_to have_key(:crypto_payments)
      expect(settings.to_h[:booking]).not_to have_key(:moon_phase)
      expect(settings.to_h).not_to have_key(:billing)
      expect(settings.unknown_keys).to contain_exactly("features.crypto_payments", "booking.moon_phase", "billing")
    end

    it "still keeps the declared keys that came alongside the junk" do
      settings = described_class.new(features: { spaces: true, nonsense: true })

      expect(settings.feature?(:spaces)).to be(true)
    end
  end

  describe "casting" do
    it "accepts the booleans a JSON body or a form actually sends" do
      expect(described_class.new(features: { spaces: "true" }).feature?(:spaces)).to be(true)
      expect(described_class.new(features: { spaces: 1 }).feature?(:spaces)).to be(true)
      expect(described_class.new(features: { bookings: "false" }).feature?(:bookings)).to be(false)
      expect(described_class.new(features: { bookings: 0 }).feature?(:bookings)).to be(false)
    end

    it "falls back to the default rather than reading a typo as false" do
      expect(described_class.new(features: { bookings: "yes please" }).feature?(:bookings)).to be(true)
    end

    it "parses a numeric string" do
      expect(described_class.new(booking: { cancellation_hours: "12" }).cancellation_hours).to eq(12)
    end

    it "clamps an out-of-range number to the nearest legal value" do
      expect(described_class.new(booking: { cancellation_hours: 10_000 }).cancellation_hours).to eq(168)
      expect(described_class.new(booking: { cancellation_hours: -5 }).cancellation_hours).to eq(0)
    end

    it "keeps zero, which means 'right up to the start'" do
      expect(described_class.new(booking: { cancellation_hours: 0 }).cancellation_hours).to eq(0)
    end
  end

  describe "#merge" do
    it "changes only what the patch names" do
      settings = described_class.new(features: { spaces: true }, booking: { cancellation_hours: 24 })

      merged = settings.merge(booking: { booking_opens_days: 30 })

      expect(merged.booking_opens_days).to eq(30)
      expect(merged.cancellation_hours).to eq(24)
      expect(merged.feature?(:spaces)).to be(true)
    end

    it "returns a new object and leaves the original alone" do
      settings = described_class.new(features: { spaces: true })

      merged = settings.merge(features: { spaces: false })

      expect(merged.feature?(:spaces)).to be(false)
      expect(settings.feature?(:spaces)).to be(true)
    end

    it "is a no-op for a patch that is not a hash" do
      settings = described_class.new(features: { spaces: true })

      expect(settings.merge(nil)).to eq(settings)
    end
  end

  describe "round-tripping through the column" do
    it "survives being written and read back" do
      company = create(:company)
      company.settings = { features: { spaces: true, waitlist: true }, booking: { cancellation_hours: 48 } }
      company.save!

      reloaded = Company.find(company.id)

      expect(reloaded.feature?(:spaces)).to be(true)
      expect(reloaded.feature?(:waitlist)).to be(true)
      expect(reloaded.settings.cancellation_hours).to eq(48)
    end

    it "keeps earlier settings when a later write touches one section" do
      company = create(:company)
      company.update!(settings: { features: { spaces: true } })
      company.update!(settings: { booking: { cancellation_hours: 5 } })

      expect(company.reload.feature?(:spaces)).to be(true)
      expect(company.settings.cancellation_hours).to eq(5)
    end

    it "clears the memoized object on reload" do
      company = create(:company)
      company.settings
      Company.find(company.id).update!(settings: { features: { spaces: true } })

      expect(company.reload.feature?(:spaces)).to be(true)
    end
  end

  describe "opening hours" do
    it "defaults to a weekday business open 06:00 to 22:00" do
      settings = described_class.default

      expect(settings.business_hours_start).to eq("06:00")
      expect(settings.business_hours_end).to eq("22:00")
      expect(settings.working_days).to eq([ 1, 2, 3, 4, 5 ])
    end

    it "answers whether the business is open on a given date" do
      settings = described_class.new(hours: { working_days: [ 1, 2, 3 ] })

      expect(settings.working_day?(Date.new(2026, 9, 21))).to be(true)   # Monday
      expect(settings.working_day?(Date.new(2026, 9, 26))).to be(false)  # Saturday
    end

    it "accepts a Time, as the old column stored it" do
      settings = described_class.new(hours: { start: Time.utc(2000, 1, 1, 7, 30) })

      expect(settings.business_hours_start).to eq("07:30")
    end

    it "sorts and de-duplicates the working days" do
      settings = described_class.new(hours: { working_days: [ 3, 1, 1, 2 ] })

      expect(settings.working_days).to eq([ 1, 2, 3 ])
    end

    it "records an unusable time rather than storing it" do
      settings = described_class.new(hours: { start: "twenty past nine" })

      expect(settings.business_hours_start).to eq("06:00")
      expect(settings.invalid_values).to include("hours.start")
    end

    it "records an empty or out-of-range working-day list" do
      expect(described_class.new(hours: { working_days: [] }).invalid_values)
        .to include("hours.working_days")
      expect(described_class.new(hours: { working_days: [ 1, 9 ] }).invalid_values)
        .to include("hours.working_days")
    end
  end

  describe "branding" do
    it "has no colour of its own by default" do
      expect(described_class.default.primary_color).to be_nil
    end

    it "keeps a valid hex colour" do
      expect(described_class.new(branding: { primary_color: "#ff5500" }).primary_color).to eq("#ff5500")
    end

    it "records an unusable colour rather than storing it" do
      settings = described_class.new(branding: { primary_color: "not-a-colour" })

      expect(settings.primary_color).to be_nil
      expect(settings.invalid_values).to include("branding.primary_color")
    end
  end

  describe "onboarding progress" do
    it "starts empty" do
      expect(described_class.default.onboarding).to eq(completed: [], skipped: [])
    end

    it "keeps only steps the catalogue knows" do
      settings = described_class.new(onboarding: { completed: %w[company billing], skipped: %w[staff] })

      expect(settings.onboarding_completed).to eq(%w[company])
      expect(settings.onboarding_skipped).to eq(%w[staff])
    end

    it "replaces a list rather than accumulating, so a step can be un-skipped" do
      settings = described_class.new(onboarding: { skipped: %w[spaces staff] })

      expect(settings.merge(onboarding: { skipped: %w[staff] }).onboarding_skipped).to eq(%w[staff])
    end

    it "leaves the other sections alone when progress changes" do
      settings = described_class.new(features: { spaces: true }, booking: { cancellation_hours: 24 })

      merged = settings.merge(onboarding: { completed: %w[company] })

      expect(merged.feature?(:spaces)).to be(true)
      expect(merged.cancellation_hours).to eq(24)
    end
  end

  describe "a company writing them" do
    it "still reads and writes them the way the rest of the app expects" do
      company = create(:company, primary_color: "#123456", working_days: [ 0, 6 ])

      expect(company.reload.primary_color).to eq("#123456")
      expect(company.working_days).to eq([ 0, 6 ])
      expect(company.working_day?(Date.new(2026, 9, 26))).to be(true)
    end

    it "refuses an unusable value instead of silently dropping it" do
      company = build(:company, primary_color: "rouge")

      expect(company).not_to be_valid
      expect(company.errors[:primary_color]).to be_present
    end

    it "keeps one section when another is written" do
      company = create(:company, primary_color: "#123456")
      company.update!(working_days: [ 1, 2 ])

      expect(company.reload.primary_color).to eq("#123456")
      expect(company.working_days).to eq([ 1, 2 ])
    end
  end

  describe "the studio settings" do
    it "lets the desk take drop-ins, keeps packs out of the catalogue, and reminds a day ahead by app only" do
      settings = described_class.default

      expect(settings.feature?(:drop_in)).to be(true)
      expect(settings.feature?(:packs)).to be(false)
      expect(settings.reminder_hours).to eq(24)
      expect(settings.reminder_sms?).to be(false)
    end

    it "clamps the reminder window to what the scan looks ahead" do
      expect(described_class.new(booking: { reminder_hours: 500 }).reminder_hours).to eq(72)
      expect(described_class.new(booking: { reminder_hours: -3 }).reminder_hours).to eq(0)
    end
  end
end
