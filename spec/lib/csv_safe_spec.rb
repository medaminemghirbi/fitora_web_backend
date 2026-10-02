require "rails_helper"

RSpec.describe CsvSafe do
  it "turns a formula into text" do
    expect(described_class.cell("=HYPERLINK(\"http://evil\",\"x\")")).to start_with("'=")
    expect(described_class.cell("@SUM(A1)")).to eq("'@SUM(A1)")
    expect(described_class.cell("+cmd|'/c calc'!A0")).to start_with("'+")
    expect(described_class.cell("-2+3")).to eq("'-2+3")
    expect(described_class.cell("\tx")).to eq("'\tx")
  end

  it "leaves phone numbers, amounts and ordinary names alone" do
    expect(described_class.cell("+216 20 111 111")).to eq("+216 20 111 111")
    expect(described_class.cell("-12.5")).to eq("-12.5")
    expect(described_class.cell("Salma")).to eq("Salma")
    expect(described_class.cell(42)).to eq(42)
    expect(described_class.cell(nil)).to be_nil
  end

  it "escapes every row of an export" do
    member = create(:client, first_name: "=1+1")
    csv = DataExchange::Clients.export_csv(member.companies.first)

    expect(CSV.parse(csv, headers: true).first["first_name"]).to eq("'=1+1")
  end
end
