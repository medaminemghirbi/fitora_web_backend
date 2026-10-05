require "rails_helper"

RSpec.describe Receipts::ContractAgreementPdf do
  let(:company) { create(:company, city: "Sousse", signatory_name: "Sami Trabelsi, gérant") }
  let(:contract) do
    create(:contract, client: create(:client, company: company), contract_type: create(:contract_type, company: company))
  end

  def images_in(pdf)
    pdf.scan("/Subtype /Image").size
  end

  it "renders a one-page PDF" do
    pdf = described_class.call(contract: contract)

    expect(pdf.byteslice(0, 4)).to eq("%PDF")
    expect(pdf.scan(%r{/Type /Page\b}).size).to eq(1)
  end

  it "prints the gym's default signature" do
    expect(images_in(described_class.call(contract: contract))).to eq(0)

    company.signature.attach(fixture_file_upload("sample.png", "image/png"))

    expect(images_in(described_class.call(contract: contract.reload))).to be > 0
  end

  it "prints the gym's logo" do
    company.logo.attach(fixture_file_upload("sample.png", "image/png"))

    expect(images_in(described_class.call(contract: contract.reload))).to be > 0
  end

  it "prints the gym's own terms instead of the default ones" do
    default = described_class.call(contract: contract)
    company.update!(contract_terms: "1. Le vestiaire ferme à 22h.\n2. Serviette obligatoire.")

    expect(described_class.call(contract: contract.reload)).not_to eq(default)
  end

  it "names the contract it renews" do
    renewed = create(:contract, client: contract.client, contract_type: contract.contract_type, renewed_from: contract,
                                starts_at: 29.days.from_now, expires_at: 59.days.from_now)

    expect(described_class.call(contract: renewed).byteslice(0, 4)).to eq("%PDF")
  end
end

RSpec.describe Receipts::PrintableImage do
  it "leaves out an image the PDF cannot embed, such as WebP" do
    webp = double("attachment", attached?: true, content_type: "image/webp")

    expect(described_class.io(webp)).to be_nil
  end

  it "has nothing to print when nothing is attached" do
    expect(described_class.io(create(:company).signature)).to be_nil
  end
end
