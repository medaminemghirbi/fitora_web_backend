require "rails_helper"

RSpec.describe PayoutAccount do
  around do |example|
    original = ENV.to_h.slice("FITORA_RIB", "FITORA_BANK_NAME", "FITORA_ACCOUNT_HOLDER", "FITORA_SWIFT")
    example.run
  ensure
    %w[FITORA_RIB FITORA_BANK_NAME FITORA_ACCOUNT_HOLDER FITORA_SWIFT].each { |k| ENV.delete(k) }
    original.each { |k, v| ENV[k] = v }
  end

  describe ".current" do
    it "is nil when no RIB is configured, so the page can fall back" do
      ENV.delete("FITORA_RIB")
      expect(described_class.current).to be_nil
    end

    it "treats a blank RIB as no RIB at all" do
      ENV["FITORA_RIB"] = "   "
      expect(described_class.current).to be_nil
    end

    it "reads the account out of the environment" do
      ENV["FITORA_RIB"] = "  TN59 1000 6035 0123 4567 8901  "
      ENV["FITORA_BANK_NAME"] = "BIAT"
      ENV["FITORA_ACCOUNT_HOLDER"] = "Fitora SARL"

      account = described_class.current

      expect(account.rib).to eq("TN59 1000 6035 0123 4567 8901")
      expect(account.bank_name).to eq("BIAT")
      expect(account.holder).to eq("Fitora SARL")
      expect(account.swift).to be_nil
    end
  end

  describe ".reference_for" do
    it "builds a reference a bank line can be matched to a gym by" do
      company = build(:company, name: "Gym Élite")
      expect(described_class.reference_for(company)).to eq("FIT-GYMELITE")
    end

    it "keeps the reference short enough for a transfer label" do
      company = build(:company, name: "A" * 40)
      expect(described_class.reference_for(company).length).to eq(20)
    end

    it "falls back to the bare prefix when the name leaves nothing usable" do
      company = build(:company, name: "!!!")
      expect(described_class.reference_for(company)).to eq("FIT")
    end

    it "is nil without a company" do
      expect(described_class.reference_for(nil)).to be_nil
    end
  end
end
