require "rails_helper"

# The server runs in UTC; a gym does not. At 23:30 UTC on 30 September it is
# already 1 October in Tunis, and "starts today" must mean the gym's today.
RSpec.describe "A request runs in the gym's time zone", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin, timezone: "Africa/Tunis") }

  it "starts a subscription sold just after the gym's midnight on the gym's date" do
    activity = create(:activity, company: company)
    plan = create(:contract_type, company: company, active: true, activity: activity)
    client = create(:client, company: company)

    travel_to Time.utc(2026, 9, 30, 23, 30) do
      post "/api/v1/contracts", params: { client_id: client.id, contract_type_id: plan.id, activity_id: activity.id },
                                headers: auth_headers(admin)
    end

    expect(response).to have_http_status(:created)
    starts_at = Contract.find(response.parsed_body.dig("contract", "id")).starts_at
    expect(starts_at.in_time_zone("Africa/Tunis").to_date).to eq(Date.new(2026, 10, 1))
  end

  it "refuses a time zone nobody has heard of" do
    company.timezone = "Mars/Olympus"

    expect(company).not_to be_valid
    expect(company.errors[:timezone]).to be_present
  end
end
