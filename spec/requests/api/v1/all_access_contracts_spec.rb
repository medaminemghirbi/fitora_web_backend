require "rails_helper"

# An all-access contract has no `activity` of its own — it covers everything
# its plan covers. Making `contracts.activity_id` nullable created that shape
# without auditing the code that read `contract.activity.name`, and four
# places would have raised on the first one sold: the contract serializer,
# the CSV export, the receipt PDF and the member's own app.
#
# These are the paths a real all-access contract travels. Each one is a
# regression test for a NoMethodError on nil.
RSpec.describe "An all-access contract", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, :pro, admin: admin) }
  let(:pilates) { create(:activity, company: company, name: "Pilates") }
  let(:boxing) { create(:activity, company: company, name: "Boxe") }
  let(:plan) { create(:contract_type, company: company, name: "Tout accès", activity: pilates) }
  let(:member) { create(:client, company: company) }

  let!(:contract) do
    create(:contract_type_activity, contract_type: plan, activity: boxing)
    create(:contract, company: company, client: member, contract_type: plan, activity: nil)
  end

  it "serializes with a null activity and says why" do
    get "/api/v1/contracts/#{contract.id}", headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    body = response.parsed_body["contract"]
    expect(body["activity"]).to be_nil
    expect(body["all_access"]).to be(true)
    expect(body["activity_label"]).to include("Pilates").and include("Boxe")
  end

  it "appears in the list without raising" do
    get "/api/v1/contracts", headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["contracts"].map { |c| c["id"] }).to include(contract.id)
  end

  it "exports to CSV with the activities it covers, not a blank" do
    get "/api/v1/data_exchange/contracts/export", headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Pilates")
  end

  it "prints a receipt" do
    get "/api/v1/contracts/#{contract.id}/receipt", headers: auth_headers(admin)

    expect(response).to have_http_status(:ok)
    expect(response.body).to start_with("%PDF")
  end

  it "shows up in the member's own app" do
    get "/api/v1/me/profile", headers: auth_headers(member)

    expect(response).to have_http_status(:ok)
    subscription = response.parsed_body["subscription"]
    expect(subscription["all_access"]).to be(true)
    expect(subscription["activity_name"]).to include("Pilates")
    expect(subscription["activity_emoji"]).to be_nil
  end

  it "lets the member book any activity the plan covers" do
    session = create(:session, company: company, activity: boxing,
                               starts_at: 2.days.from_now, ends_at: 2.days.from_now + 1.hour)

    post "/api/v1/me/bookings", params: { session_id: session.id }, headers: auth_headers(member)

    expect(response).to have_http_status(:created)
  end

  it "still refuses an activity the plan does not cover" do
    yoga = create(:activity, company: company, name: "Yoga")
    session = create(:session, company: company, activity: yoga,
                               starts_at: 2.days.from_now, ends_at: 2.days.from_now + 1.hour)

    post "/api/v1/me/bookings", params: { session_id: session.id }, headers: auth_headers(member)

    expect(response).to have_http_status(:unprocessable_content)
  end

  describe "#activity_label" do
    it "names the one activity when the contract names one" do
      single = create(:contract, company: company, client: create(:client, company: company),
                                 contract_type: plan, activity: pilates)

      expect(single.activity_label).to eq("Pilates")
    end

    it "falls back to a dash rather than an empty string when a plan covers nothing" do
      empty_plan = create(:contract_type, company: company)
      empty_plan.contract_type_activities.destroy_all
      orphan = build(:contract, company: company, client: create(:client, company: company),
                                contract_type: empty_plan, activity: nil)
      orphan.save!(validate: false)

      expect(orphan.activity_label).to eq("—")
    end
  end
end
