require "rails_helper"

# The paths a pack travels once the gym has one: priced on a formule, sold
# at the desk, filtered on in the members list, booked from the member app.
RSpec.describe "Selling a pack", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, :pro, :with_packs, admin: admin) }
  let(:boxe) { create(:activity, company: company, name: "Boxe") }
  let(:muscu) { create(:activity, company: company, name: "Musculation") }
  let(:yoga) { create(:activity, company: company, name: "Yoga") }
  let!(:pack) { create(:pack, company: company, name: "Duo", activities: [ boxe, muscu ]) }
  let(:plan) { create(:contract_type, company: company, activity: yoga, price: 60) }
  let(:member) { create(:client, company: company) }

  describe "on the formule" do
    it "stores a price per pack beside the activities' prices" do
      patch "/api/v1/contract_types/#{plan.id}", params: { contract_type: { name: plan.name }, pack_prices: [ { pack_id: pack.id, price: 110 } ] },
                                                 headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["plan"]
      expect(body["pack_prices"]).to contain_exactly(include("pack_id" => pack.id, "price" => "110.0", "activity_names" => %w[Boxe Musculation]))
      expect(body["activity_prices"].size).to eq(1) # untouched: not sent
    end

    it "leaves the packs alone when only the activities are repriced" do
      create(:contract_type_pack, contract_type: plan, pack: pack, price: 110)

      patch "/api/v1/contract_types/#{plan.id}", params: { contract_type: { name: plan.name }, activity_prices: [ { activity_id: yoga.id, price: 65 } ] },
                                                 headers: auth_headers(admin)

      expect(plan.reload.price_for_pack(pack)).to eq(110)
    end

    it "clears the packs when an empty list is sent" do
      create(:contract_type_pack, contract_type: plan, pack: pack, price: 110)

      patch "/api/v1/contract_types/#{plan.id}", params: { contract_type: { name: plan.name }, pack_prices: [] },
                                                 headers: auth_headers(admin), as: :json

      expect(plan.reload.contract_type_packs).to be_empty
    end

    it "takes the prices alone, without the formule's own fields" do
      patch "/api/v1/contract_types/#{plan.id}", params: { pack_prices: [ { pack_id: pack.id, price: 95 } ] }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(plan.reload.price_for_pack(pack)).to eq(95)
    end

        it "ignores another gym's pack" do
      foreign = create(:pack)

      patch "/api/v1/contract_types/#{plan.id}", params: { contract_type: { name: plan.name }, pack_prices: [ { pack_id: foreign.id, price: 1 } ] },
                                                 headers: auth_headers(admin)

      expect(plan.reload.contract_type_packs).to be_empty
    end
  end

  context "once priced" do
    before { create(:contract_type_pack, contract_type: plan, pack: pack, price: 110) }

    it "sells it at the desk, at the pack's price" do
      post "/api/v1/contracts", params: { client_id: member.id, contract_type_id: plan.id, pack_id: pack.id }, headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      contract = response.parsed_body["contract"]
      expect(contract["pack"]).to include("id" => pack.id, "name" => "Duo")
      expect(contract["activity"]).to be_nil
      expect(contract["all_access"]).to be(false)
      expect(contract["final_price"]).to eq("110.0")
      expect(contract["activity_label"]).to eq("Duo (Boxe, Musculation)")
    end

    it "404s on a deactivated pack" do
      pack.update!(active: false)

      post "/api/v1/contracts", params: { client_id: member.id, contract_type_id: plan.id, pack_id: pack.id }, headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "sells it with a new member" do
      post "/api/v1/clients",
           params: { client: { first_name: "Sami", last_name: "Ben Ali", phone: "+21620000000" },
                     subscription: { contract_type_id: plan.id, pack_id: pack.id } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(Contract.find_by(pack: pack)).to be_present
    end

    it "finds the pack's holders when the members list is filtered on one of its activities" do
      create(:contract, contract_type: plan, activity: nil, pack: pack, client: member, company: company)

      get "/api/v1/clients", params: { activity_id: boxe.id }, headers: auth_headers(admin)

      expect(response.parsed_body["clients"].map { |c| c["id"] }).to include(member.id)
    end

    it "lets the member book an activity of the pack, and not one outside it" do
      create(:contract, contract_type: plan, activity: nil, pack: pack, client: member, company: company)
      in_pack = create(:session, company: company, activity: muscu, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 1.hour)
      outside = create(:session, company: company, activity: yoga, starts_at: 3.days.from_now, ends_at: 3.days.from_now + 1.hour)

      post "/api/v1/me/bookings", params: { session_id: in_pack.id }, headers: auth_headers(member)
      expect(response).to have_http_status(:created)

      post "/api/v1/me/bookings", params: { session_id: outside.id }, headers: auth_headers(member)
      expect(response).not_to have_http_status(:created)
    end
  end
end
