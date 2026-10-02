require "rails_helper"

# One gym must never reach another gym's data.
#
# Every example here is a denial. They exist as one file, rather than
# scattered through the per-resource specs, so that "what can this role
# reach" can be reviewed by reading one thing — and so that a new endpoint
# that forgets to scope itself fails a spec whose name says why.
#
# Cross-tenant reads must return 404, never 403: a 403 confirms the record
# exists, which is itself a leak.
RSpec.describe "Security: tenant isolation", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin) }

  let(:other_admin) { create(:user, :admin) }
  let!(:other_company) { create(:company, admin: other_admin) }

  describe "an admin reaching into another company" do
    it "cannot read another company's member" do
      theirs = create(:client, company: other_company)

      get "/api/v1/clients/#{theirs.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "cannot edit another company's member" do
      theirs = create(:client, company: other_company)

      patch "/api/v1/clients/#{theirs.id}", params: { client: { first_name: "Taken" } },
                                            headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
      expect(theirs.reload.first_name).not_to eq("Taken")
    end

    it "cannot read another company's activity" do
      theirs = create(:activity, company: other_company)

      get "/api/v1/activities/#{theirs.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "cannot read another company's session" do
      theirs = create(:session, company: other_company, activity: create(:activity, company: other_company))

      get "/api/v1/sessions/#{theirs.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "cannot cancel another company's session" do
      theirs = create(:session, company: other_company, activity: create(:activity, company: other_company))

      post "/api/v1/sessions/#{theirs.id}/cancel", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
      expect(theirs.reload).to be_scheduled
    end

    it "cannot read another company's booking" do
      theirs = create(:booking,
        session: create(:session, company: other_company, activity: create(:activity, company: other_company)),
        client: create(:client, company: other_company))

      get "/api/v1/bookings/#{theirs.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "cannot cancel another company's booking" do
      theirs = create(:booking,
        session: create(:session, company: other_company, activity: create(:activity, company: other_company)),
        client: create(:client, company: other_company))

      post "/api/v1/bookings/#{theirs.id}/cancel", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
      expect(theirs.reload).to be_confirmed
    end

    it "cannot read another company's contract" do
      theirs = create(:contract, company: other_company, client: create(:client, company: other_company),
                                 contract_type: create(:contract_type, company: other_company))

      get "/api/v1/contracts/#{theirs.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "cannot read another company's coach" do
      theirs = create(:coach, company: other_company)

      get "/api/v1/coaches/#{theirs.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "cannot read another company's staff seat" do
      theirs = create(:staff_member, company: other_company)

      get "/api/v1/staff/#{theirs.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "cannot switch to a company they do not own" do
      post "/api/v1/companies/#{other_company.id}/switch", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
      expect(admin.reload.active_company_id).not_to eq(other_company.id)
    end
  end

  describe "list endpoints" do
    it "never mix two companies' members, activities, sessions or contracts" do
      mine = create(:client, company: company)
      theirs = create(:client, company: other_company)
      create(:activity, company: other_company)
      create(:session, company: other_company, activity: create(:activity, company: other_company))

      get "/api/v1/clients", headers: auth_headers(admin)
      ids = response.parsed_body["clients"].map { |c| c["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(theirs.id)

      get "/api/v1/activities", headers: auth_headers(admin)
      expect(response.parsed_body["activities"]).to be_empty

      get "/api/v1/sessions", headers: auth_headers(admin)
      expect(response.parsed_body["sessions"]).to be_empty
    end
  end

  describe "mass assignment" do
    it "ignores a company_id in the body when creating an activity" do
      post "/api/v1/activities",
           params: { activity: { name: "Smuggled", session_format: "collective", duration: 60,
                                 capacity: 12, company_id: other_company.id } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(Activity.find_by(name: "Smuggled").company_id).to eq(company.id)
    end

    it "ignores a company_id in the body when creating a member" do
      post "/api/v1/clients",
           params: { client: { first_name: "Smuggled", last_name: "Member", phone: "20000000",
                               company_id: other_company.id } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(other_company.clients.where(first_name: "Smuggled")).to be_empty
      expect(company.clients.where(first_name: "Smuggled")).to be_present
    end
  end

  describe "a member of one gym" do
    let(:member) { create(:client, company: company) }

    before { create(:subscription, :pro, company: company) }

    it "cannot pass another gym's company_id to see its schedule" do
      get "/api/v1/me/sessions", params: { company_id: other_company.id }, headers: auth_headers(member)

      expect(response).to have_http_status(:not_found)
    end

    it "cannot book a session at a gym they have not joined" do
      theirs = create(:session, company: other_company, activity: create(:activity, company: other_company))

      post "/api/v1/me/bookings", params: { session_id: theirs.id }, headers: auth_headers(member)

      expect(response).to have_http_status(:not_found)
    end

    it "cannot reach another member's booking" do
      someone_else = create(:booking, session: create(:session, company: company,
                                                               activity: create(:activity, company: company)),
                                      client: create(:client, company: company))

      post "/api/v1/me/bookings/#{someone_else.id}/cancel", headers: auth_headers(member)

      expect(response).to have_http_status(:not_found)
      expect(someone_else.reload).to be_confirmed
    end
  end

  describe "unauthenticated access" do
    %w[
      /api/v1/clients /api/v1/activities /api/v1/sessions /api/v1/bookings
      /api/v1/contracts /api/v1/payments /api/v1/staff /api/v1/roles
      /api/v1/coaches /api/v1/spaces /api/v1/audit_logs /api/v1/notifications
      /api/v1/me/profile /api/v1/me/bookings /api/v1/superadmin/companies
    ].each do |path|
      it "refuses #{path}" do
        get path

        expect(response).to have_http_status(:unauthorized)
      end
    end

    it "refuses a token signed with the wrong secret" do
      forged = JWT.encode({ user_id: admin.id, exp: 1.hour.from_now.to_i }, "not-the-secret")

      get "/api/v1/clients", headers: { "Authorization" => "Bearer #{forged}" }

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
