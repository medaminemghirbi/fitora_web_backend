require "rails_helper"

RSpec.describe EmailMask do
  it "keeps two letters at each end of the name, and the whole domain" do
    expect(described_class.call("example@gmail.com")).to eq("ex****le@gmail.com")
    expect(described_class.call("sami.trabelsi@studio.tn")).to eq("sa****si@studio.tn")
  end

  it "shows only the first letter of a short name" do
    expect(described_class.call("ab@x.tn")).to eq("a****@x.tn")
  end

  it "leaves a blank address blank" do
    expect(described_class.call(nil)).to be_nil
    expect(described_class.call("")).to eq("")
  end

  it "knows a masked value from a real address" do
    expect(described_class.masked?("ex****le@gmail.com")).to be(true)
    expect(described_class.masked?("example@gmail.com")).to be(false)
  end
end
