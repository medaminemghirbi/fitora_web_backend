require "rails_helper"

RSpec.describe "Api::V1::Clients", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin) }

  describe "POST /api/v1/clients" do
    it "creates a client with only first name, last name, and phone required" do
      post "/api/v1/clients", params: { client: { first_name: "Ahmed", last_name: "Ben Ali", phone: "+216 20 000 000" } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["client"]["full_name"]).to eq("Ahmed Ben Ali")
    end

    it "rejects a client with no phone" do
      post "/api/v1/clients", params: { client: { first_name: "Ahmed", last_name: "Ben Ali" } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "is never blocked by any client count — no plans, no limits" do
      create_list(:client, 5, company: company)

      post "/api/v1/clients", params: { client: { first_name: "Ahmed", last_name: "Ben Ali", phone: "20000000" } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
    end

    it "logs an audit entry for the new client" do
      post "/api/v1/clients", params: { client: { first_name: "Ahmed", last_name: "Ben Ali", phone: "20000000" } }, headers: auth_headers(admin)

      log = AuditLog.last
      expect(log.action).to eq("client.created")
      expect(log.company_id).to eq(company.id)
    end
  end

  describe "GET /api/v1/clients" do
    it "searches across name, phone, and email" do
      create(:client, company: company, first_name: "Ahmed", last_name: "Ben Ali", phone: "20111111")
      create(:client, company: company, first_name: "Leila", last_name: "Gharbi", phone: "20222222")

      get "/api/v1/clients", params: { search: "ahmed" }, headers: auth_headers(admin)

      names = response.parsed_body["clients"].map { |c| c["full_name"] }
      expect(names).to eq([ "Ahmed Ben Ali" ])
    end

    it "filters by contract_active status" do
      with_contract = create(:client, company: company)
      create(:contract, client: with_contract, company: company, status: :active, expires_at: 10.days.from_now)
      without_contract = create(:client, company: company)

      get "/api/v1/clients", params: { status: "contract_active" }, headers: auth_headers(admin)

      ids = response.parsed_body["clients"].map { |c| c["id"] }
      expect(ids).to include(with_contract.id)
      expect(ids).not_to include(without_contract.id)
    end

    it "narrows the list to the holders of one plan" do
      plan = create(:contract_type, company: company)
      holder = create(:client, company: company)
      create(:contract, client: holder, company: company, contract_type: plan)
      outsider = create(:client, company: company)

      get "/api/v1/clients", params: { contract_type_id: plan.id }, headers: auth_headers(admin)

      ids = response.parsed_body["clients"].map { |c| c["id"] }
      expect(ids).to eq([ holder.id ])
      expect(ids).not_to include(outsider.id)
    end

    it "counts an all-access contract as covering the activity it is filtered on" do
      yoga = create(:activity, company: company)
      plan = create(:contract_type, company: company, activity: yoga)
      all_access = create(:client, company: company)
      create(:contract, client: all_access, company: company, contract_type: plan, activity: nil)

      get "/api/v1/clients", params: { activity_id: yoga.id }, headers: auth_headers(admin)

      ids = response.parsed_body["clients"].map { |c| c["id"] }
      expect(ids).to eq([ all_access.id ])
    end

    it "narrows on when someone joined the gym" do
      old_hand = create(:client, company: company, joined_at: 2.years.ago)
      newcomer = create(:client, company: company, joined_at: 2.days.ago)

      get "/api/v1/clients", params: { joined_from: 1.month.ago.to_date.to_s }, headers: auth_headers(admin)

      ids = response.parsed_body["clients"].map { |c| c["id"] }
      expect(ids).to eq([ newcomer.id ])
      expect(ids).not_to include(old_hand.id)
    end

    it "orders on a whitelisted column and ignores anything else" do
      first_in = create(:client, company: company, first_name: "Zora", joined_at: 3.years.ago)
      last_in = create(:client, company: company, first_name: "Amel", joined_at: 1.day.ago)

      get "/api/v1/clients", params: { sort: "joined", direction: "desc" }, headers: auth_headers(admin)
      expect(response.parsed_body["clients"].map { |c| c["id"] }).to eq([ last_in.id, first_in.id ])

      get "/api/v1/clients", params: { sort: "; DROP TABLE clients" }, headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["clients"].map { |c| c["id"] }).to eq([ last_in.id, first_in.id ])
    end

    it "counts each status against the advanced filters, not the whole gym" do
      plan = create(:contract_type, company: company)
      holder = create(:client, company: company)
      create(:contract, client: holder, company: company, contract_type: plan, status: :active, expires_at: 10.days.from_now)
      create(:client, company: company)

      get "/api/v1/clients", params: { contract_type_id: plan.id }, headers: auth_headers(admin)

      expect(response.parsed_body["counts"]["all"]).to eq(1)
      expect(response.parsed_body["counts"]["no_contract"]).to eq(0)
    end

    it "never exposes another company's clients" do
      create(:client, company: company)
      other_org_client = create(:client)

      get "/api/v1/clients", headers: auth_headers(admin)

      ids = response.parsed_body["clients"].map { |c| c["id"] }
      expect(ids).not_to include(other_org_client.id)
    end

    it "forbids a coach from browsing the client list" do
      coach_staff = create(:staff_member, company: company, role: :coach)

      get "/api/v1/clients", headers: auth_headers(coach_staff.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "lets a moderator browse the client list" do
      moderator = create(:staff_member, company: company, role: :moderator)
      create(:client, company: company)

      get "/api/v1/clients", headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/v1/clients/:id" do
    it "returns the client's overview payload including outstanding balance and attendance rate" do
      client = create(:client, company: company)

      get "/api/v1/clients/#{client.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["client"]
      expect(body["outstanding_balance"].to_f).to eq(0)
      expect(body["attendance_rate"]).to be_nil
    end
  end

  describe "the filter rail's counts" do
    it "reports how many clients each status holds, for the current search" do
      create(:client, company: company, first_name: "Rania", active: true)
      create(:client, company: company, first_name: "Dorra", active: false)
      create(:client, company: company, first_name: "Sofiane", active: true)

      get "/api/v1/clients", headers: auth_headers(admin)

      counts = response.parsed_body["counts"]
      expect(counts["all"]).to eq(3)
      expect(counts["active"]).to eq(2)
      expect(counts["inactive"]).to eq(1)
      expect(counts["no_contract"]).to eq(3)
    end

    it "narrows the counts with the search term rather than the picked status" do
      create(:client, company: company, first_name: "Rania", active: true)
      create(:client, company: company, first_name: "Dorra", active: false)

      get "/api/v1/clients", params: { search: "rania", status: "inactive" }, headers: auth_headers(admin)

      counts = response.parsed_body["counts"]
      expect(counts["all"]).to eq(1)
      expect(counts["active"]).to eq(1)
      expect(counts["inactive"]).to eq(0)
    end
  end

  describe "POST /api/v1/clients — signing someone up in one go" do
    let(:activity) { create(:activity, company: company) }
    let(:plan) { create(:contract_type, company: company) }

    before { create(:contract_type_activity, contract_type: plan, activity: activity, price: 120) }

    def sign_up(subscription, user: admin)
      post "/api/v1/clients",
           params: {
             client: { first_name: "Rania", last_name: "Ferjani", phone: "20000001" },
             subscription: subscription
           },
           headers: auth_headers(user)
    end

    it "records the member, sells the plan and takes the money in one request" do
      sign_up({ contract_type_id: plan.id, activity_id: activity.id, collect_payment: true, payment_method: "cash" })

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["client"]["first_name"]).to eq("Rania")
      expect(body["contract"]["id"]).to be_present
      expect(body["payment"]["amount"].to_f).to eq(120.0)

      client = Client.find(body["client"]["id"])
      expect(client.current_contract(company)).to be_present
      expect(client.current_contract(company)).to be_paid
    end

    it "sells the plan without taking money when the desk is not collecting yet" do
      sign_up({ contract_type_id: plan.id, activity_id: activity.id })

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["payment"]).to be_nil
      expect(Client.find(response.parsed_body["client"]["id"]).current_contract(company)).to be_unpaid
    end

    it "still records a member on their own when no plan is picked" do
      post "/api/v1/clients",
           params: { client: { first_name: "Sans", last_name: "Abonnement", phone: "20000002" } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["contract"]).to be_nil
    end

    it "leaves no half-signed-up member behind when the plan has no price for that activity" do
      other = create(:activity, company: company, name: "Pilates")

      expect { sign_up({ contract_type_id: plan.id, activity_id: other.id }) }.not_to change(Client, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("Pilates")
    end

    it "refuses another gym's plan without creating anyone" do
      elsewhere = create(:contract_type, company: create(:company))

      expect { sign_up({ contract_type_id: elsewhere.id, activity_id: activity.id }) }.not_to change(Client, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses the sale to a login that may record members but not sell plans" do
      limited = create(:role, company: company, key: "front-desk", name: "Accueil", permissions: %w[clients])
      staff = create(:staff_member, company: company, role: :moderator, assigned_role: limited)

      expect { sign_up({ contract_type_id: plan.id, activity_id: activity.id }, user: staff.user) }
        .not_to change(Client, :count)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
