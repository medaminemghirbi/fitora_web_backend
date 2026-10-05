require "rails_helper"

RSpec.describe "Api::V1::Packs", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, :pro, :with_packs, admin: admin) }
  let(:boxe) { create(:activity, company: company, name: "Boxe") }
  let(:muscu) { create(:activity, company: company, name: "Musculation") }
  let(:yoga) { create(:activity, company: company, name: "Yoga") }

  describe "GET /api/v1/packs" do
    it "lists the gym's packs with their activities and their price per formule" do
      pack = create(:pack, company: company, name: "Duo", activities: [ boxe, muscu ])
      plan = create(:contract_type, company: company, name: "Mensuel")
      create(:contract_type_pack, contract_type: plan, pack: pack, price: 110)
      create(:pack) # another gym's

      get "/api/v1/packs", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      packs = response.parsed_body["packs"]
      expect(packs.size).to eq(1)
      expect(packs.first["activities"].map { |a| a["name"] }).to eq(%w[Boxe Musculation])
      expect(packs.first["prices"].first).to include("contract_type_name" => "Mensuel", "price" => "110.0")
    end

    it "lets a moderator read them, to sign a member up" do
      moderator = create(:staff_member, company: company, role: :moderator)

      get "/api/v1/packs", headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/v1/packs" do
    it "creates a pack of several activities" do
      post "/api/v1/packs", params: { pack: { name: "Duo" }, activity_ids: [ boxe.id, muscu.id ] }, headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["pack"]["activity_ids"]).to contain_exactly(boxe.id, muscu.id)
    end

    it "refuses a pack of one activity" do
      post "/api/v1/packs", params: { pack: { name: "Solo" }, activity_ids: [ boxe.id ] }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(company.packs.count).to eq(0)
    end

    it "ignores another gym's activity" do
      elsewhere = create(:activity)

      post "/api/v1/packs", params: { pack: { name: "Duo" }, activity_ids: [ boxe.id, elsewhere.id ] }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "forbids a moderator — building the offer is configuration" do
      moderator = create(:staff_member, company: company, role: :moderator)

      post "/api/v1/packs", params: { pack: { name: "Duo" }, activity_ids: [ boxe.id, muscu.id ] }, headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PATCH /api/v1/packs/:id" do
    let!(:pack) { create(:pack, company: company, name: "Duo", activities: [ boxe, muscu ]) }

    it "renames it and changes what it holds" do
      patch "/api/v1/packs/#{pack.id}", params: { pack: { name: "Trio" }, activity_ids: [ boxe.id, muscu.id, yoga.id ] },
                                        headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(pack.reload.name).to eq("Trio")
      expect(pack.activities).to contain_exactly(boxe, muscu, yoga)
    end

    it "keeps its activities when a refused edit would leave it with one" do
      patch "/api/v1/packs/#{pack.id}", params: { pack: { name: "Duo" }, activity_ids: [ boxe.id ] }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(pack.reload.activities).to contain_exactly(boxe, muscu)
    end

    it "leaves the activities alone when none are sent" do
      patch "/api/v1/packs/#{pack.id}", params: { pack: { description: "Deux disciplines" } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(pack.reload.activities.count).to eq(2)
    end
  end

  describe "DELETE /api/v1/packs/:id" do
    it "deactivates rather than deletes, so contracts sold with it keep it" do
      pack = create(:pack, company: company)

      delete "/api/v1/packs/#{pack.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(pack.reload).not_to be_active
    end
  end
end
