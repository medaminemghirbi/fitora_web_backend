require "rails_helper"

RSpec.describe "Member invitations", type: :request do
  let(:company) { create(:company, :pro) }
  let(:member) { create(:client, company: company, email: "member@example.com") }

  describe "POST /api/v1/clients/:id/invite" do
    it "emails the member a link instead of taking a password" do
      expect {
        post "/api/v1/clients/#{member.id}/invite", headers: auth_headers(company.admin)
      }.to have_enqueued_mail(AccountMailer, :member_invitation)

      expect(response).to have_http_status(:accepted)
      expect(member.reload.login_enabled?).to be(false)
      expect(member.invitation_pending?).to be(true)
    end

    it "refuses a member with no email" do
      walk_in = create(:client, company: company, email: nil)
      post "/api/v1/clients/#{walk_in.id}/invite", headers: auth_headers(company.admin)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses someone who already signs in" do
      member.update!(password: "already-set-1")
      post "/api/v1/clients/#{member.id}/invite", headers: auth_headers(company.admin)

      expect(response.parsed_body["error"]).to eq("already_enabled")
    end

    it "does not send twice on a double click" do
      post "/api/v1/clients/#{member.id}/invite", headers: auth_headers(company.admin)
      post "/api/v1/clients/#{member.id}/invite", headers: auth_headers(company.admin)

      expect(response.parsed_body["error"]).to eq("invitation_recently_sent")
    end

    it "is refused on Starter: the member app comes with Pro" do
      company.subscription.update!(plan: :starter)

      expect {
        post "/api/v1/clients/#{member.id}/invite", headers: auth_headers(company.admin)
      }.not_to have_enqueued_mail(AccountMailer, :member_invitation)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("member_app_not_included")
    end

    it "is refused for another gym's member" do
      post "/api/v1/clients/#{member.id}/invite", headers: auth_headers(create(:company).admin)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/invitations/:token" do
    let!(:raw) { member.generate_invitation_token! }

    it "lets the member choose a password and sign in with it" do
      patch "/api/v1/invitations/#{raw}", params: { password: "chosen-by-me" }
      expect(response).to have_http_status(:no_content)

      post "/api/v1/auth/login", params: { email: "member@example.com", password: "chosen-by-me" }
      expect(response.parsed_body["account_type"]).to eq("client")
      expect(member.reload.email_verified?).to be(true)
    end

    it "works once" do
      patch "/api/v1/invitations/#{raw}", params: { password: "chosen-by-me" }
      patch "/api/v1/invitations/#{raw}", params: { password: "second-try-1" }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses a blank password without using up the link" do
      patch "/api/v1/invitations/#{raw}", params: { password: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(member.reload.invitation_token_valid?(raw)).to be(true)
    end

    it "expires after a week" do
      travel 8.days do
        patch "/api/v1/invitations/#{raw}", params: { password: "chosen-by-me" }
      end

      expect(response.parsed_body["error"]).to eq("invalid_or_expired_token")
    end
  end
end
