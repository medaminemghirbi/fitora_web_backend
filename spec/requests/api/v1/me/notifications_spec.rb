require "rails_helper"

RSpec.describe "A member's own notifications", type: :request do
  let(:company) { create(:company) }
  let(:member) { create(:client, company: company, password: "member-pass-1") }
  let(:headers) { { "Authorization" => "Bearer #{JwtService.for_client(member)}" } }
  let(:activity) { create(:activity, company: company) }
  let(:session) { create(:session, activity: activity) }

  before do
    plan = create(:contract_type, company: company, activity: activity)
    create(:contract, client: member, contract_type: plan, activity: activity)
  end

  it "tells them when their class is called off" do
    session.book!(member)
    session.cancel!

    get "/api/v1/me/notifications", headers: headers

    kinds = response.parsed_body["notifications"].map { |n| n["kind"] }
    expect(kinds).to eq([ "session_cancelled" ])
    expect(response.parsed_body["unread_count"]).to eq(1)
  end

  it "tells them when a seat comes free from the waitlist" do
    company.update!(settings: { features: { waitlist: true } })
    session.update!(capacity: 1)
    seated = create(:client, company: company)
    create(:contract, client: seated, contract_type: create(:contract_type, company: company, activity: activity), activity: activity)
    seat = session.book!(seated)
    session.book!(member)

    seat.cancel!

    expect(member.notifications.pluck(:kind)).to eq([ "waitlist_promoted" ])
  end

  it "says nothing to a member without the app" do
    walk_in = create(:client, company: company)
    Notification.push(recipient: walk_in, company: company, kind: "session_cancelled", data: {}, url: "/", dedup_key: "x")

    expect(walk_in.notifications).to be_empty
  end

  it "marks them read, and only theirs" do
    session.book!(member)
    session.cancel!
    note = member.notifications.first

    patch "/api/v1/me/notifications/#{note.id}/read", headers: headers
    expect(note.reload).to be_read

    patch "/api/v1/me/notifications/#{note.id}/read", headers: auth_headers(company.admin)
    expect(response).to have_http_status(:forbidden)
  end

  it "keeps the admin's feed closed to a member token" do
    get "/api/v1/notifications", headers: headers

    expect(response).to have_http_status(:forbidden)
  end
end
