require "rails_helper"

RSpec.describe Pack do
  let(:company) { create(:company) }
  let(:boxe) { create(:activity, company: company, name: "Boxe") }
  let(:muscu) { create(:activity, company: company, name: "Musculation") }

  it "bundles at least two activities" do
    pack = build(:pack, company: company, activities: [ boxe ])

    expect(pack).not_to be_valid
    expect(pack.errors[:activities]).to be_present
  end

  it "refuses another gym's activity" do
    elsewhere = create(:activity)
    pack = build(:pack, company: company, activities: [ boxe, elsewhere ])

    expect(pack).not_to be_valid
  end

  it "covers exactly the activities it holds" do
    pack = create(:pack, company: company, activities: [ boxe, muscu ])

    expect(pack.covers?(boxe)).to be(true)
    expect(pack.covers?(create(:activity, company: company))).to be(false)
    expect(pack.covers?(nil)).to be(false)
  end

  it "names its activities in order, for a label" do
    pack = create(:pack, company: company, activities: [ muscu, boxe ])

    expect(pack.activity_names).to eq(%w[Boxe Musculation])
  end

  it "cannot be destroyed while a contract was sold with it" do
    pack = create(:pack, company: company, activities: [ boxe, muscu ])
    plan = create(:contract_type, company: company)
    create(:contract_type_pack, contract_type: plan, pack: pack)
    create(:contract, contract_type: plan, activity: nil, pack: pack, client: create(:client, company: company))

    expect(pack.destroy).to be(false)
  end
end
