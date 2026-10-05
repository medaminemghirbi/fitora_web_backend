require "rails_helper"

RSpec.describe "Api::V1::Notifications", type: :request do
  let(:company) { create(:company) }
  let(:admin) { company.admin }

  def make(n, read: false, key_prefix: "k")
    n.times.map { |i| create(:notification, company: company, recipient: admin, dedup_key: "#{key_prefix}:#{i}", read_at: read ? Time.current : nil) }
  end

  describe "GET /api/v1/notifications" do
    it "paginates 10 per page, newest first, with the unread count" do
      make(14)
      get "/api/v1/notifications", headers: auth_headers(admin)

      body = response.parsed_body
      expect(body["notifications"].size).to eq(10)
      expect(body["meta"]).to include("page" => 1, "per_page" => 10, "total" => 14, "total_pages" => 2)
      expect(body["unread_count"]).to eq(14)

      get "/api/v1/notifications", params: { page: 2 }, headers: auth_headers(admin)
      expect(response.parsed_body["notifications"].size).to eq(4)
    end

    it "forbids staff" do
      staff = create(:staff_member, company: company)
      get "/api/v1/notifications", headers: auth_headers(staff.user)
      expect(response).to have_http_status(:forbidden)
    end

    it "also serves a Fitora superadmin's own notifications (e.g. system_update)" do
      superadmin = create(:user, :superadmin)
      create(:notification, company: nil, recipient: superadmin, kind: "system_update", dedup_key: "system_update-1")

      get "/api/v1/notifications", headers: auth_headers(superadmin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["notifications"].size).to eq(1)
    end

    it "never leaks another admin's notifications" do
      make(2)
      other = create(:notification, dedup_key: "other")
      get "/api/v1/notifications", headers: auth_headers(admin)
      ids = response.parsed_body["notifications"].map { |n| n["id"] }
      expect(ids).not_to include(other.id)
    end
  end

  describe "PATCH /api/v1/notifications/:id/read" do
    it "marks one notification read" do
      n = make(1).first
      patch "/api/v1/notifications/#{n.id}/read", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      expect(n.reload).to be_read
    end
  end

  describe "POST /api/v1/notifications/read_all" do
    it "marks everything read" do
      make(3)
      post "/api/v1/notifications/read_all", headers: auth_headers(admin)
      expect(response).to have_http_status(:no_content)
      expect(admin.notifications.unread.count).to eq(0)
    end
  end

  describe "GET /api/v1/notifications/unread_count" do
    it "returns the count" do
      make(2)
      make(1, read: true, key_prefix: "r")
      get "/api/v1/notifications/unread_count", headers: auth_headers(admin)
      expect(response.parsed_body["count"]).to eq(2)
    end
  end
end
