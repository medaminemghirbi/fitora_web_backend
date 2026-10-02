require "rails_helper"

RSpec.describe SubscriptionPrice do
  describe ".for" do
    it "creates the reference (TND) Starter row at its default price" do
      row = described_class.for("TND", plan: "starter")
      expect(row.monthly_cents).to eq(described_class::DEFAULT_MONTHLY_CENTS["starter"])
    end

    it "prices Pro from its own default, above Starter's" do
      expect(described_class.for("TND", plan: "pro").monthly_cents).to eq(described_class::DEFAULT_MONTHLY_CENTS["pro"])
      expect(described_class::DEFAULT_MONTHLY_CENTS["pro"]).to be > described_class::DEFAULT_MONTHLY_CENTS["starter"]
    end

    it "seeds a newly-seen currency's plan from the same plan's TND reference price" do
      described_class.for("TND", plan: "pro").update!(monthly_cents: 31_000)

      expect(described_class.for("EUR", plan: "pro").monthly_cents).to eq(31_000)
    end

    it "defaults a blank currency to the reference" do
      expect(described_class.for(nil, plan: "starter").currency).to eq("TND")
    end

    it "reads an unknown plan as Starter rather than raising" do
      expect(described_class.for("TND", plan: "enterprise").plan).to eq("starter")
    end

    it "keeps each plan of a currency priced independently" do
      described_class.for("TND", plan: "starter").update!(monthly_cents: 10_000)
      described_class.for("TND", plan: "pro").update!(monthly_cents: 20_000)

      expect(described_class.for("TND", plan: "starter").monthly_cents).to eq(10_000)
      expect(described_class.for("TND", plan: "pro").monthly_cents).to eq(20_000)
    end
  end

  describe "#annual_cents" do
    it "is twelve months less the platform's annual discount" do
      PlatformSetting.current.update!(annual_discount_percent: 10)
      price = described_class.for("TND", plan: "starter")
      price.update!(monthly_cents: 10_000)

      expect(price.annual_cents).to eq(108_000)
    end
  end

  it "validates the currency, the plan, and a non-negative price" do
    expect(described_class.new(currency: "XXX", plan: "starter", monthly_cents: 100)).to be_invalid
    expect(described_class.new(currency: "TND", plan: "premium", monthly_cents: 100)).to be_invalid
    expect(described_class.new(currency: "TND", plan: "starter", monthly_cents: -1)).to be_invalid
  end

  it "rejects a duplicate currency+plan pair" do
    create(:subscription_price, currency: "EUR", plan: "starter")
    duplicate = build(:subscription_price, currency: "EUR", plan: "starter")

    expect(duplicate).not_to be_valid
  end

  it "allows the same currency on the other plan" do
    create(:subscription_price, currency: "EUR", plan: "starter")
    other_plan = build(:subscription_price, currency: "EUR", plan: "pro")

    expect(other_plan).to be_valid
  end
end
