require "rails_helper"

# A pack contract opens every activity of its pack, at the pack's price on
# the formule — neither the activities' own prices nor the plan's other
# activities come into it.
RSpec.describe Contract, "sold with a pack" do
  let(:company) { create(:company) }
  let(:boxe) { create(:activity, company: company, name: "Boxe") }
  let(:muscu) { create(:activity, company: company, name: "Musculation") }
  let(:yoga) { create(:activity, company: company, name: "Yoga") }
  let(:pack) { create(:pack, company: company, name: "Duo", activities: [ boxe, muscu ]) }
  let(:plan) { create(:contract_type, company: company, activity: yoga, price: 60) }
  let(:client) { create(:client, company: company) }
  let(:staff) { create(:user, :admin) }

  before { create(:contract_type_pack, contract_type: plan, pack: pack, price: 110) }

  def sell(**options)
    Contract.sell!(client: client, contract_type: plan, activity: nil, pack: pack, created_by: staff, **options)
  end

  it "is sold at the pack's price on the formule" do
    contract = sell

    expect(contract.pack).to eq(pack)
    expect(contract.activity).to be_nil
    expect(contract.final_price).to eq(110)
  end

  it "drops an activity passed beside the pack rather than selling both" do
    contract = Contract.sell!(client: client, contract_type: plan, activity: boxe, pack: pack, created_by: staff)

    expect(contract.activity).to be_nil
    expect(contract.pack).to eq(pack)
  end

  it "refuses a pack the formule has no price for" do
    other = create(:pack, company: company, activities: [ boxe, yoga ])

    expect {
      Contract.sell!(client: client, contract_type: plan, activity: nil, pack: other, created_by: staff)
    }.to raise_error(ApplicationRecord::Refused, /pack/)
  end

  it "covers the pack's activities and nothing else, the formule's own included" do
    contract = sell

    expect(contract.covers_activity?(boxe)).to be(true)
    expect(contract.covers_activity?(muscu)).to be(true)
    expect(contract.covers_activity?(yoga)).to be(false)
    expect(contract).not_to be_all_access
  end

  it "stops covering once the formule no longer sells the pack" do
    contract = sell
    plan.contract_type_packs.destroy_all

    expect(contract.reload.covers_activity?(boxe)).to be(false)
  end

  it "says what it is in words" do
    expect(sell.activity_label).to eq("Duo (Boxe, Musculation)")
  end

  it "renews at today's pack price" do
    contract = sell
    travel_to(contract.expires_at - 5.days)
    plan.contract_type_packs.find_by(pack: pack).update!(price: 130)

    expect(contract.renew!.base_price).to eq(130)
  end

  it "is a different sale from the same formule for one of the pack's activities" do
    plan.contract_type_activities.create!(activity: boxe, price: 70)
    sell
    Contract.sell!(client: client, contract_type: plan, activity: boxe, created_by: staff)

    expect(client.contracts.count).to eq(2)
  end

  it "never holds an activity and a pack together" do
    contract = sell
    contract.activity = boxe

    expect(contract).not_to be_valid
    expect { contract.save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
  end
end
