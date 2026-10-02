require "rails_helper"

RSpec.describe Reports::CompanyWorkbook do
  it "builds a summary sheet and a color-coded clients sheet scoped to the period" do
    company = create(:company, name: "Studio Test")
    period = Reports::Period.parse(period_type: "month", period: "2025-03")

    client_active = create(:client, company: company, active: true, first_name: "Amina", last_name: "K")
    client_inactive = create(:client, company: company, active: false, first_name: "Youssef", last_name: "B")

    plan = create(:contract_type, company: company, price: 100)
    contract = create(:contract, client: client_active, contract_type: plan)
    period_record = contract.current_period

    create(:payment, company: company, client: client_active, contract_period: period_record,
                      amount: 60, payment_method: :cash, status: :paid, paid_at: Time.zone.local(2025, 3, 10))
    create(:payment, company: company, client: client_active, contract_period: period_record,
                      amount: 40, payment_method: :bank_transfer, status: :paid, paid_at: Time.zone.local(2025, 3, 15))
    # Outside the requested period — must not be counted anywhere.
    create(:payment, company: company, client: client_active, contract_period: period_record,
                      amount: 999, payment_method: :cash, status: :paid, paid_at: Time.zone.local(2025, 2, 1))

    package = described_class.call(company: company, period: period)

    expect(package).to be_a(Axlsx::Package)
    sheets = package.workbook.worksheets
    expect(sheets.map(&:name)).to eq(%w[Résumé Clients])

    summary = sheets.find { |s| s.name == "Résumé" }
    expect(summary.rows.first.cells.first.value).to eq("Rapport Gymly — Studio Test")
    expect(summary.rows[1].cells.first.value).to eq("Période : #{period.label}")

    revenue_row = summary.rows.find { |r| r.cells[0]&.value == "Revenu total" }
    expect(revenue_row.cells[1].value).to eq(100)

    cash_row = summary.rows.find { |r| r.cells[0]&.value == "  dont espèces" }
    expect(cash_row.cells[1].value).to eq(60)

    bank_row = summary.rows.find { |r| r.cells[0]&.value == "  dont virement" }
    expect(bank_row.cells[1].value).to eq(40)

    expect(summary.rows.find { |r| r.cells[0]&.value == "Clients actifs" }.cells[1].value).to eq(1)
    expect(summary.rows.find { |r| r.cells[0]&.value == "Clients inactifs" }.cells[1].value).to eq(1)

    clients_sheet = sheets.find { |s| s.name == "Clients" }
    client_rows = clients_sheet.rows.to_a.drop(1)
    expect(client_rows.size).to eq(2)

    active_row = client_rows.find { |r| r.cells[0]&.value == "Amina K" }
    expect(active_row.cells[3].value).to eq("Actif")
    expect(active_row.cells[5].value).to eq(100)

    inactive_row = client_rows.find { |r| r.cells[0]&.value == "Youssef B" }
    expect(inactive_row.cells[3].value).to eq("Inactif")
    expect(inactive_row.cells[5].value).to eq(0)
  end

  it "builds a valid, empty workbook for a company with no clients or payments in the period" do
    company = create(:company)
    period = Reports::Period.parse(period_type: "month", period: "2025-01")

    package = described_class.call(company: company, period: period)

    summary = package.workbook.worksheets.find { |s| s.name == "Résumé" }
    revenue_row = summary.rows.find { |r| r.cells[0]&.value == "Revenu total" }
    expect(revenue_row.cells[1].value).to eq(0)

    clients_sheet = package.workbook.worksheets.find { |s| s.name == "Clients" }
    expect(clients_sheet.rows.size).to eq(1) # header row only
  end
end
