require "rails_helper"

RSpec.describe "Api::V1::ActivityTemplates", type: :request do
  it "serves the active catalogue to an admin who has no salle yet" do
    create(:activity_template, key: "boxe", family: "combat", names: { "fr" => "Boxe", "en" => "Boxing" })
    create(:activity_template, key: "retired", active: false)

    get "/api/v1/activity_templates", headers: auth_headers(create(:user, :admin))

    expect(response).to have_http_status(:ok)
    body = response.parsed_body["activity_templates"]
    expect(body.map { |t| t["key"] }).to eq([ "boxe" ])
    expect(body.first).to include("family" => "combat", "names" => { "fr" => "Boxe", "en" => "Boxing" })
  end
end
