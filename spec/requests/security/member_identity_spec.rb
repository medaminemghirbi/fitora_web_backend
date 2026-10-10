require "rails_helper"

# A Client is one person across every gym that knows their email. These are
# the ways a second gym used to reach through that shared row into the first
# gym's member — adopt the email, read what gym A wrote, set a password, log
# in as them. Every example is a refusal.
RSpec.describe "A member shared between gyms", type: :request do
  include ActiveJob::TestHelper

  let(:gym_a) { create(:company) }
  let(:gym_b) { create(:company) }
  let!(:member) do
    create(:client, company: gym_a, email: "member@example.com", first_name: "Salma", phone: "+216 20 111 111",
                    password: "original-pass")
  end

  before do
    member.membership_for(gym_a).update!(date_of_birth: Date.new(1990, 1, 1), address: "12 Rue A",
                                         emergency_contact_name: "Mother", emergency_contact_phone: "+216 20 222 222")
  end

  def adopt!
    post "/api/v1/clients",
         params: { client: { first_name: "Other", last_name: "Name", phone: "+216 99 999 999", email: "member@example.com" } },
         headers: auth_headers(gym_b.admin)
    expect(response).to have_http_status(:created)
    response.parsed_body.dig("client", "id")
  end

  it "joins the existing person without overwriting who they are" do
    id = adopt!

    expect(id).to eq(member.id)
    expect(member.reload.first_name).to eq("Salma")
    expect(member.phone).to eq("+216 20 111 111")
  end

  it "shows the second gym none of what the first gym wrote" do
    id = adopt!
    get "/api/v1/clients/#{id}", headers: auth_headers(gym_b.admin)

    client = response.parsed_body["client"]
    expect(client.values_at("date_of_birth", "address", "emergency_contact_name", "emergency_contact_phone")).to all(be_nil)
  end

  it "keeps each gym's copy apart when the second gym writes its own" do
    id = adopt!
    patch "/api/v1/clients/#{id}", params: { client: { address: "7 Rue B" } }, headers: auth_headers(gym_b.admin)

    expect(response).to have_http_status(:ok)
    expect(member.membership_for(gym_a).reload.address).to eq("12 Rue A")
    expect(member.membership_for(gym_b).reload.address).to eq("7 Rue B")
  end

  it "never takes a password from staff" do
    id = adopt!
    patch "/api/v1/clients/#{id}", params: { client: { password: "attacker-pass" } }, headers: auth_headers(gym_b.admin)

    expect(member.reload.authenticate("attacker-pass")).to be(false)
    expect(member.authenticate("original-pass")).to be_truthy
  end

  it "refuses to change the email, name or phone of someone who is not only this gym's" do
    id = adopt!
    patch "/api/v1/clients/#{id}", params: { client: { email: "attacker@example.com", first_name: "Changed" } },
                                   headers: auth_headers(gym_b.admin)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to eq("identity_locked")
    expect(member.reload.email).to eq("member@example.com")
    expect(member.first_name).to eq("Salma")
  end

  it "does not let the first gym change it either once the person signs in themselves" do
    patch "/api/v1/clients/#{member.id}", params: { client: { email: "new@example.com" } }, headers: auth_headers(gym_a.admin)

    expect(response).to have_http_status(:unprocessable_content)
    expect(member.reload.email).to eq("member@example.com")
  end

  it "still lets a gym fill in what is blank, and resend what is already there" do
    member.update_columns(phone: nil) # rubocop:disable Rails/SkipsModelValidations
    id = adopt!
    member.update_columns(phone: nil) # rubocop:disable Rails/SkipsModelValidations

    patch "/api/v1/clients/#{id}", params: { client: { first_name: "Salma", phone: "+216 20 333 333" } },
                                   headers: auth_headers(gym_b.admin)

    expect(response).to have_http_status(:ok)
    expect(member.reload.phone).to eq("+216 20 333 333")
  end

  it "leaves a person only this gym knows fully editable" do
    walk_in = create(:client, company: gym_a, first_name: "Typo")
    patch "/api/v1/clients/#{walk_in.id}", params: { client: { first_name: "Fixed", email: "walkin@example.com" } },
                                           headers: auth_headers(gym_a.admin)

    expect(response).to have_http_status(:ok)
    expect(walk_in.reload.first_name).to eq("Fixed")
    expect(walk_in.email).to eq("walkin@example.com")
  end

  it "harvests nothing through a CSV import either" do
    create(:subscription, :pro, company: gym_b)
    csv = Rack::Test::UploadedFile.new(StringIO.new("first_name,last_name,email,phone\nX,Y,member@example.com,1\n"), "text/csv",
                                       original_filename: "members.csv")
    perform_enqueued_jobs do
      post "/api/v1/data_exchange/clients/import", params: { file: csv }, headers: auth_headers(gym_b.admin)
    end
    expect(gym_b.clients).to include(member)
    get "/api/v1/clients/#{member.id}", headers: auth_headers(gym_b.admin)

    expect(response.parsed_body.dig("client", "address")).to be_nil
    expect(member.reload.first_name).to eq("Salma")
  end
end
