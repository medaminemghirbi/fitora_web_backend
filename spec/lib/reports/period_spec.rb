require "rails_helper"

RSpec.describe Reports::Period do
  it "parses a year into a full calendar-year range" do
    result = described_class.parse(period_type: "year", period: "2025")

    expect(result.kind).to eq("year")
    expect(result.label).to eq("2025")
    expect(result.slug).to eq("2025")
    expect(result.range.begin).to eq(Time.zone.local(2025, 1, 1))
    expect(result.range.end).to eq(Time.zone.local(2025, 12, 31, 23, 59, 59))
  end

  it "parses a month into a French-labelled month range" do
    result = described_class.parse(period_type: "month", period: "2025-03")

    expect(result.kind).to eq("month")
    expect(result.label).to eq("mars 2025")
    expect(result.slug).to eq("2025-03")
    expect(result.range.begin).to eq(Time.zone.local(2025, 3, 1).beginning_of_month)
    expect(result.range.end).to eq(Time.zone.local(2025, 3, 1).end_of_month)
  end

  it "rejects a year outside the supported range" do
    expect { described_class.parse(period_type: "year", period: "1999") }
      .to raise_error(Reports::Period::InvalidPeriod, "year out of range")
  end

  it "rejects a month number outside 1-12" do
    expect { described_class.parse(period_type: "month", period: "2025-13") }
      .to raise_error(Reports::Period::InvalidPeriod, "month out of range")
  end

  it "rejects an unknown period_type" do
    expect { described_class.parse(period_type: "week", period: "2025-03") }
      .to raise_error(Reports::Period::InvalidPeriod, 'unknown period_type "week"')
  end

  it "wraps unparsable period values in InvalidPeriod" do
    expect { described_class.parse(period_type: "year", period: "not-a-year") }
      .to raise_error(Reports::Period::InvalidPeriod, 'could not parse period "not-a-year"')
  end
end
