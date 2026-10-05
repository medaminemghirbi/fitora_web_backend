require "rails_helper"

RSpec.describe "Api::V1::Activities", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin) }

  describe "GET /api/v1/activities" do
    it "never exposes another company's activities" do
      mine = create(:activity, company: company)
      theirs = create(:activity)

      get "/api/v1/activities", headers: auth_headers(admin)

      ids = response.parsed_body["activities"].map { |a| a["id"] }
      expect(ids).to include(mine.id)
      expect(ids).not_to include(theirs.id)
    end

    it "lets a moderator list them — needed to fill the new-session form" do
      create(:activity, company: company)
      moderator = create(:staff_member, company: company, role: :moderator)

      get "/api/v1/activities", headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["activities"].size).to eq(1)
    end

    it "forbids a coach — they only view the calendar, not the catalogue" do
      coach_staff = create(:staff_member, company: company, role: :coach)

      get "/api/v1/activities", headers: auth_headers(coach_staff.user)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/activities/adopt" do
    let(:template) { create(:activity_template, names: { "fr" => "Boxe" }, emoji: "🥊") }

    it "adds the picked templates as the salle's own activities" do
      post "/api/v1/activities/adopt", params: { activity_template_ids: [ template.id ] }, headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      created = response.parsed_body["activities"]
      expect(created.map { |a| [ a["name"], a["emoji"], a["activity_template_id"] ] }).to eq([ [ "Boxe", "🥊", template.id ] ])
      expect(company.activities.count).to eq(1)
    end

    it "forbids a moderator" do
      moderator = create(:staff_member, company: company, role: :moderator)

      post "/api/v1/activities/adopt", params: { activity_template_ids: [ template.id ] }, headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:forbidden)
      expect(company.activities).to be_empty
    end
  end

  describe "POST /api/v1/activities" do
    it "forbids a moderator — editing the catalogue needs the activities capability" do
      moderator = create(:staff_member, company: company, role: :moderator)

      post "/api/v1/activities",
           params: { activity: { name: "Yoga", session_format: "collective", duration: 60, capacity: 12 } },
           headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "lets a staff member whose role grants :activities create one" do
      staff = create(:staff_member, company: company, role: :moderator,
                     assigned_role: create(:role, company: company, permissions: %w[activities]))

      post "/api/v1/activities",
           params: { activity: { name: "Yoga", session_format: "collective", duration: 60, capacity: 12 } },
           headers: auth_headers(staff.user)

      expect(response).to have_http_status(:created)
      expect(company.activities.pluck(:name)).to include("Yoga")
    end

    it "rejects a capacity that does not match the session format" do
      post "/api/v1/activities",
           params: { activity: { name: "Duo", session_format: "small_group", duration: 60, capacity: 20 } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to match(/between 2 and 9/)
    end
  end
end
