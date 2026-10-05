require "rails_helper"

# The moderator runs the back office: members and coaches, day to day. Who
# becomes a moderator — and anything that decides who can do what — stays
# the admin's. Every way up is refused here.
RSpec.describe "A moderator's reach", type: :request do
  let(:company) { create(:company) }
  let(:moderator) { create(:staff_member, company: company, role: :moderator).user }
  let(:headers) { auth_headers(moderator) }

  describe "what is theirs to manage" do
    it "adds a member and changes their details" do
      post "/api/v1/clients", params: { client: { first_name: "New", last_name: "Member", phone: "+216 20 555 555" } },
                              headers: headers
      expect(response).to have_http_status(:created)

      patch "/api/v1/clients/#{response.parsed_body.dig('client', 'id')}", params: { client: { notes: "knee" } }, headers: headers
      expect(response).to have_http_status(:ok)
    end

    it "adds a coach and gives them their login" do
      post "/api/v1/coaches", params: { coach: { first_name: "Karim", last_name: "Coach" } }, headers: headers
      expect(response).to have_http_status(:created)

      coach_id = response.parsed_body.dig("coach", "id")
      post "/api/v1/coaches/#{coach_id}/login", params: { email: "karim@example.com", password: "coach-pass-1" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(StaffMember.find_by(coach_id: coach_id).role_key).to eq("coach")
    end
  end

  describe "what stays the admin's" do
    it "cannot create a staff login" do
      post "/api/v1/staff", params: { staff_member: { first_name: "A", last_name: "B", email: "ab@example.com",
                                                      password: "password123", role: "moderator" } },
                            headers: headers

      expect(response).to have_http_status(:forbidden)
    end

    it "cannot promote anyone, themselves included" do
      coach = create(:staff_member, company: company, role: :coach)
      own_seat = moderator.staff_member

      [ coach, own_seat ].each do |seat|
        patch "/api/v1/staff/#{seat.id}", params: { staff_member: { role: "admin" } }, headers: headers
        expect(response).to have_http_status(:forbidden)
      end
      expect(coach.reload.role_key).to eq("coach")
    end

    it "cannot create, re-permission or delete a role" do
      role = company.roles.find_by(key: "moderator")

      post "/api/v1/roles", params: { role: { name: "Boss", permissions: Permission::ALL } }, headers: headers
      expect(response).to have_http_status(:forbidden)
      patch "/api/v1/roles/#{role.id}", params: { role: { permissions: Permission::ALL } }, headers: headers
      expect(response).to have_http_status(:forbidden)
      delete "/api/v1/roles/#{company.roles.find_by(key: 'coach').id}", headers: headers
      expect(response).to have_http_status(:forbidden)

      expect(role.reload.permissions).not_to include("settings")
    end

    it "cannot take over a higher login through the coach it is attached to" do
      coach = create(:coach, company: company)
      full_access = create(:staff_member, company: company, role: :admin, coach: coach)

      post "/api/v1/coaches/#{coach.id}/login", params: { email: "mine@example.com", password: "taken-over-1" },
                                                headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(full_access.user.reload.email).not_to eq("mine@example.com")
    end

    it "cannot change the company, its settings or its Fitora billing" do
      patch "/api/v1/company", params: { company: { name: "Mine" } }, headers: headers
      expect(response).to have_http_status(:forbidden)

      get "/api/v1/subscription", headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "leaves the admin free to reset any login attached to a coach" do
    coach = create(:coach, company: company)
    create(:staff_member, company: company, role: :moderator, coach: coach)

    post "/api/v1/coaches/#{coach.id}/login", params: { email: "reset@example.com", password: "reset-pass-1" },
                                              headers: auth_headers(company.admin)

    expect(response).to have_http_status(:ok)
  end
end
