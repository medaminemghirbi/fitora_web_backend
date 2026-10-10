require "rails_helper"

# Access is a boolean. These are the two ways it becomes false, and what
# each one tells the person who hits the door.
RSpec.describe "Access lock", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin) }
  let(:staff) { create(:staff_member, company: company, role: :moderator).user }

  describe "a gym whose access is open" do
    it "is never blocked" do
      create(:subscription, company: company)
      create(:invoice, :current, company: company)

      get "/api/v1/clients", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "a gym whose access is closed" do
    it "blocks the admin out of ordinary company endpoints" do
      create(:subscription, :closed, company: company)

      get "/api/v1/clients", headers: auth_headers(admin)

      expect(response).to have_http_status(:payment_required)
    end

    it "says it is the money when the invoices ran out" do
      create(:subscription, :closed, company: company)
      create(:invoice, :lapsed, company: company)

      get "/api/v1/clients", headers: auth_headers(admin)

      expect(response.parsed_body["error"]).to eq("unpaid")
      expect(response.parsed_body["message"]).to include("settle")
    end

    it "says it was a decision when the gym is paid up" do
      create(:subscription, :closed, company: company)
      create(:invoice, :current, company: company)

      get "/api/v1/clients", headers: auth_headers(admin)

      expect(response.parsed_body["error"]).to eq("suspended")
      expect(response.parsed_body["message"]).to include("suspended")
    end

    it "tells staff to talk to their admin, never what is owed" do
      create(:subscription, :closed, company: company)
      create(:invoice, :lapsed, company: company)

      get "/api/v1/clients", headers: auth_headers(staff)

      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body["message"]).to include("gym's admin")
      expect(response.parsed_body["message"]).not_to include("settle")
    end

    it "blocks every staff role, not only the admin" do
      create(:subscription, :closed, company: company)

      get "/api/v1/clients", headers: auth_headers(staff)

      expect(response).to have_http_status(:payment_required)
    end
  end

  # The way out must never be behind the door it closed.
  describe "what a locked admin can still reach" do
    before do
      create(:subscription, :closed, company: company)
      create(:invoice, :lapsed, company: company)
    end

    it "sees what they owe" do
      get "/api/v1/subscription", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
    end

    it "lists the invoices they already have" do
      get "/api/v1/invoices", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
    end

    it "downloads one of them" do
      invoice = company.subscription.invoices.first

      get "/api/v1/invoices/#{invoice.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
    end

    it "still switches to another salle of theirs" do
      company.subscription.update!(plan: :pro)
      other = create(:company, admin: admin)

      post "/api/v1/companies/#{other.id}/switch", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
    end
  end

  # One account, one door: the plan and its access cover every salle.
  it "locks every salle of the account at once" do
    other = create(:company, admin: admin)
    create(:subscription, :closed, company: company)
    admin.update!(active_company: other)

    get "/api/v1/clients", headers: auth_headers(admin)

    expect(response).to have_http_status(:payment_required)
  end
end
