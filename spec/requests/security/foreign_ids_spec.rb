require "rails_helper"

# A few endpoints accept an id for something OTHER than the record being
# written — a coach to attach to a staff seat, a role to assign, an
# attachment to download. Each is a chance to reach into another gym by
# supplying one of its ids, and each is refused for a different reason:
# a scoped lookup, or a model validation.
#
# These are the cases the Fitora/UnscopedTenantQuery cop cannot see, because
# nothing here is a bare `Model.find` — the id arrives inside a nested write.
RSpec.describe "Security: foreign ids in nested writes", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin) }
  let!(:other_company) { create(:company) }

  describe "assigning a staff seat" do
    it "refuses a coach belonging to another gym" do
      theirs = create(:coach, company: other_company)

      post "/api/v1/staff",
           params: { staff_member: { first_name: "A", last_name: "B", email: "ab@fitora.test",
                                     password: "password123", role: "coach", coach_id: theirs.id } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(other_company.reload.staff_members).to be_empty
    end

    it "refuses a role belonging to another gym" do
      theirs = other_company.roles.find_by(key: "moderator")

      post "/api/v1/staff",
           params: { staff_member: { first_name: "A", last_name: "B", email: "ab2@fitora.test",
                                     password: "password123", role_id: theirs.id } },
           headers: auth_headers(admin)

      # Resolved through current_company.roles, so it is not found at all.
      expect(response).to have_http_status(:not_found)
      expect(company.staff_members).to be_empty
    end

    it "refuses an unknown role key rather than creating a seat with no role" do
      post "/api/v1/staff",
           params: { staff_member: { first_name: "A", last_name: "B", email: "ab3@fitora.test",
                                     password: "password123", role: "sorcerer" } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
      expect(company.staff_members).to be_empty
    end
  end

  describe "building a session" do
    it "refuses another gym's activity" do
      theirs = create(:activity, company: other_company)

      post "/api/v1/sessions",
           params: { session: { activity_id: theirs.id, starts_at: 2.days.from_now,
                                ends_at: 2.days.from_now + 1.hour, capacity: 10 } },
           headers: auth_headers(admin)

      expect(response).not_to have_http_status(:created)
      expect(company.sessions).to be_empty
    end

    it "refuses another gym's coach" do
      mine = create(:activity, company: company)
      theirs = create(:coach, company: other_company)

      post "/api/v1/sessions",
           params: { session: { activity_id: mine.id, coach_id: theirs.id, starts_at: 2.days.from_now,
                                ends_at: 2.days.from_now + 1.hour, capacity: 10 } },
           headers: auth_headers(admin)

      expect(response).not_to have_http_status(:created)
      expect(company.sessions).to be_empty
    end

    it "refuses another gym's room" do
      company.update!(settings: { features: { spaces: true } })
      mine = create(:activity, company: company)
      theirs = create(:space, company: other_company)

      post "/api/v1/sessions",
           params: { session: { activity_id: mine.id, space_id: theirs.id, starts_at: 2.days.from_now,
                                ends_at: 2.days.from_now + 1.hour, capacity: 10 } },
           headers: auth_headers(admin)

      expect(response).not_to have_http_status(:created)
      expect(company.sessions).to be_empty
    end
  end

  describe "restricting a room to activities" do
    it "silently drops another gym's activity rather than linking it" do
      company.update!(settings: { features: { spaces: true } })
      theirs = create(:activity, company: other_company)

      post "/api/v1/spaces",
           params: { space: { name: "Studio", activity_ids: [ theirs.id ] } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["space"]["activity_ids"]).to be_empty
    end
  end

  describe "downloading a support ticket attachment" do
    it "cannot fetch an attachment through another gym's ticket" do
      theirs = create(:support_ticket, company: other_company, created_by: other_company.admin)

      get "/api/v1/support_tickets/#{theirs.id}/attachments/#{SecureRandom.uuid}",
          headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "cannot fetch an attachment id that belongs to a different ticket" do
      mine = create(:support_ticket, company: company, created_by: admin)

      get "/api/v1/support_tickets/#{mine.id}/attachments/#{SecureRandom.uuid}",
          headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end
  end
end
