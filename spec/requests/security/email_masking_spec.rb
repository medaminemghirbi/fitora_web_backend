require "rails_helper"

# Someone else's e-mail address leaves the API masked ("ex****le@gmail.com");
# the person's own session and the admin's single-coach edit view keep it
# whole, and a masked value sent back is refused rather than saved.
RSpec.describe "E-mail masking", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, :pro, admin: admin) }

  it "masks members' addresses in the member list and profile" do
    client = create(:client, company: company, email: "example@gmail.com")

    get "/api/v1/clients", headers: auth_headers(admin)
    listed = response.parsed_body["clients"].find { |c| c["id"] == client.id }
    expect(listed["email"]).to eq("ex****le@gmail.com")

    get "/api/v1/clients/#{client.id}", headers: auth_headers(admin)
    expect(response.parsed_body["client"]["email"]).to eq("ex****le@gmail.com")
  end

  it "still finds a member by a piece of their address" do
    create(:client, company: company, first_name: "Sami", email: "sami.trabelsi@studio.tn")

    get "/api/v1/clients", params: { q: "trabelsi@" }, headers: auth_headers(admin)

    expect(response.parsed_body["clients"].map { |c| c["first_name"] }).to include("Sami")
  end

  it "masks the team's addresses, and shows them whole to the admin opening one coach" do
    coach = create(:coach, company: company, email: "coach.lina@studio.tn")

    get "/api/v1/coaches", headers: auth_headers(admin)
    expect(response.parsed_body["coaches"].find { |c| c["id"] == coach.id }["email"]).to eq("co****na@studio.tn")

    get "/api/v1/coaches/#{coach.id}", headers: auth_headers(admin)
    expect(response.parsed_body["coach"]["email"]).to eq("coach.lina@studio.tn")

    moderator = create(:staff_member, company: company, role: :moderator).user
    get "/api/v1/coaches/#{coach.id}", headers: auth_headers(moderator)
    expect(response.parsed_body["coach"]["email"]).to eq("co****na@studio.tn")
  end

  it "keeps a person's own address whole in their own session" do
    get "/api/v1/auth/me", headers: auth_headers(admin)

    expect(response.parsed_body["user"]["email"]).to eq(admin.email)
  end

  it "refuses a masked address sent back, instead of saving it" do
    coach = create(:coach, company: company, email: "coach.lina@studio.tn")

    patch "/api/v1/coaches/#{coach.id}", params: { coach: { email: "co****na@studio.tn" } }, headers: auth_headers(admin)

    expect(response).to have_http_status(:unprocessable_content)
    expect(coach.reload.email).to eq("coach.lina@studio.tn")
  end
end
