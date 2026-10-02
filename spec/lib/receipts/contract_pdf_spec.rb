require "rails_helper"

RSpec.describe Receipts::ContractPdf do
  def build_contract(company:, discount: 0, paid: false)
    plan = create(:contract_type, company: company, price: 100)
    client = create(:client, company: company, phone: "+216 20 000000")
    contract = create(:contract, client: client, contract_type: plan, discount: discount,
                                  payment_status: (paid ? :paid : :unpaid))

    if paid
      create(:payment, company: company, client: client, contract_period: contract.current_period,
                        amount: contract.final_price, status: :paid)
    end

    contract
  end

  it "renders a non-empty PDF with a %PDF header" do
    company = create(:company)
    contract = build_contract(company: company)

    pdf_bytes = described_class.call(contract: contract)

    expect(pdf_bytes).to be_a(String)
    expect(pdf_bytes).not_to be_empty
    expect(pdf_bytes.byteslice(0, 4)).to eq("%PDF")
  end

  it "produces a different document when the contract carries a discount line item" do
    company = create(:company)
    no_discount = build_contract(company: company, discount: 0)
    with_discount = build_contract(company: company, discount: 15)

    pdf_no_discount = described_class.call(contract: no_discount)
    pdf_with_discount = described_class.call(contract: with_discount)

    expect(pdf_with_discount.bytesize).not_to eq(pdf_no_discount.bytesize)
  end

  it "does not raise when the client has no email on file" do
    company = create(:company)
    plan = create(:contract_type, company: company)
    client = create(:client, company: company, email: nil, phone: "20000000")
    contract = create(:contract, client: client, contract_type: plan)

    expect { described_class.call(contract: contract) }.not_to raise_error
  end

  it "renders correctly when the contract has already been paid in full" do
    company = create(:company)
    contract = build_contract(company: company, paid: true)

    pdf_bytes = described_class.call(contract: contract)

    expect(pdf_bytes.byteslice(0, 4)).to eq("%PDF")
  end
end
