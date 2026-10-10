require "rails_helper"

# X-Company-Id: the salle a browser tab is working in. Honoured only for a
# salle the login runs or works in; anything else is refused, never quietly
# swapped for the default.
RSpec.describe "Security: X-Company-Id", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:first) { create(:company, admin: admin) }
  let!(:second) { create(:company, admin: admin) }
  let!(:stranger) { create(:company) }

  def with_company(account, company_id)
    auth_headers(account).merge("X-Company-Id" => company_id.to_s)
  end

  it "scopes the request to the salle the tab names" do
    theirs = create(:client, company: second)

    get "/api/v1/clients/#{theirs.id}", headers: with_company(admin, second.id)

    expect(response).to have_http_status(:ok)
  end

  it "does not move the login's saved salle" do
    get "/api/v1/company", headers: with_company(admin, second.id)

    expect(response.parsed_body.dig("company", "id")).to eq(second.id)
    expect(admin.reload.active_company_id).to eq(first.id)
  end

  it "falls back to the saved salle without the header" do
    get "/api/v1/company", headers: auth_headers(admin)

    expect(response.parsed_body.dig("company", "id")).to eq(first.id)
  end

  it "refuses another admin's salle" do
    get "/api/v1/clients", headers: with_company(admin, stranger.id)

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["error"]).to eq("company_not_accessible")
  end

  it "refuses garbage" do
    get "/api/v1/clients", headers: with_company(admin, "not-a-uuid")

    expect(response).to have_http_status(:forbidden)
  end

  it "is applied to /auth/me too, so the tab's user names its salle" do
    get "/api/v1/auth/me", headers: with_company(admin, second.id)

    expect(response.parsed_body.dig("user", "company_id")).to eq(second.id)
  end

  describe "a staff login" do
    let(:moderator) { create(:staff_member, company: first, role: :moderator).user }

    it "works in a salle it is posted to" do
      create(:staff_member, company: second, user: moderator, role: :moderator)

      get "/api/v1/clients", headers: with_company(moderator, second.id)

      expect(response).to have_http_status(:ok)
    end

    it "is refused a salle it is not posted to" do
      get "/api/v1/clients", headers: with_company(moderator, second.id)

      expect(response).to have_http_status(:forbidden)
    end

    it "is refused a salle where its post is deactivated" do
      create(:staff_member, company: second, user: moderator, role: :moderator, active: false)

      get "/api/v1/clients", headers: with_company(moderator, second.id)

      expect(response).to have_http_status(:forbidden)
    end
  end
end
