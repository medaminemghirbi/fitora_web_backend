require "rails_helper"

RSpec.describe "Removing and erasing members", type: :request do
  let(:company) { create(:company) }
  let(:activity) { create(:activity, company: company) }

  describe "DELETE /api/v1/clients/:id" do
    let(:member) { create(:client, company: company, email: nil, notes: "knee injury") }

    it "takes the gym's copy away and cancels what they had booked" do
      booking = create(:booking, client: member, session: create(:session, activity: activity))
      delete "/api/v1/clients/#{member.id}", headers: auth_headers(company.admin)

      expect(response).to have_http_status(:no_content)
      expect(company.clients).not_to include(member)
      expect(booking.reload).to be_cancelled
    end

    it "anonymises a person nobody else knows" do
      delete "/api/v1/clients/#{member.id}", headers: auth_headers(company.admin)

      expect(member.reload.first_name).to eq(Client::PLACEHOLDER_FIRST_NAME)
      expect(member.phone).to be_nil
    end

    it "leaves someone who trains elsewhere as they are for the other gym" do
      other = create(:company)
      member.join!(other)
      delete "/api/v1/clients/#{member.id}", headers: auth_headers(company.admin)

      expect(member.reload.first_name).not_to eq(Client::PLACEHOLDER_FIRST_NAME)
      expect(other.clients).to include(member)
    end

    it "refuses while a subscription is still running" do
      create(:contract, client: member, contract_type: create(:contract_type, company: company))
      delete "/api/v1/clients/#{member.id}", headers: auth_headers(company.admin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(company.clients).to include(member)
    end

    it "keeps the gym's payments" do
      payment = create(:payment, client: member, company: company)
      delete "/api/v1/clients/#{member.id}", headers: auth_headers(company.admin)

      expect(Payment.exists?(payment.id)).to be(true)
    end
  end

  describe "the member's own account" do
    let(:member) { create(:client, company: company, email: "me@example.com", password: "my-password-1") }
    let(:headers) { { "Authorization" => "Bearer #{JwtService.for_client(member)}" } }

    it "lets them correct their own name and phone" do
      patch "/api/v1/me/profile", params: { client: { first_name: "Correct", phone: "+216 20 444 444", email: "x@y.z" } },
                                  headers: headers

      expect(response).to have_http_status(:ok)
      expect(member.reload.first_name).to eq("Correct")
      expect(member.email).to eq("me@example.com")
    end

    it "erases them on request, confirmed by their password" do
      delete "/api/v1/me/account", params: { password: "my-password-1" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(member.reload.email).to be_nil
      expect(member.login_enabled?).to be(false)

      get "/api/v1/me/profile", headers: headers
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses without the password" do
      delete "/api/v1/me/account", params: { password: "wrong" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(member.reload.email).to eq("me@example.com")
    end
  end
end
