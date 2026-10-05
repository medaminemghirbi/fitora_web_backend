require "rails_helper"

RSpec.describe "Api::V1::Companies", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin) }

  describe "GET /api/v1/company" do
    it "returns the admin's company" do
      get "/api/v1/company", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["company"]["id"]).to eq(company.id)
    end

    it "forbids staff from reading company settings" do
      staff = create(:staff_member, company: company, role: :moderator)

      get "/api/v1/company", headers: auth_headers(staff.user)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/companies — signup" do
    let(:fresh_admin) { create(:user, :admin) }

    it "gives the new company every feature" do
      post "/api/v1/companies",
           params: { company: { name: "Iron Box", timezone: "Africa/Tunis", currency: "TND" } },
           headers: auth_headers(fresh_admin)

      expect(response).to have_http_status(:created)
      created = Company.find_by(admin: fresh_admin)
      expect(created.enabled_module_keys).to match_array(%w[base] + ModuleCatalog::KEYS)
    end

    it "opens on the free trial, not on a tier" do
      post "/api/v1/companies", params: { company: { name: "Iron Box", timezone: "Africa/Tunis", currency: "TND" } },
                                 headers: auth_headers(fresh_admin)

      subscription = Company.find_by(admin: fresh_admin).subscription
      expect(subscription).to be_active
      expect(subscription).to be_trial
      expect(subscription.trial_days_left).to eq(Subscription::TRIAL_DAYS)
      expect(subscription.latest_invoice.amount_cents).to eq(0)
    end

    it "opens with the activities picked from the catalogue and the ones it named itself" do
      template = create(:activity_template, names: { "fr" => "Pilates Reformer" })

      post "/api/v1/companies",
           params: { company: { name: "Studio Sousse", timezone: "Africa/Tunis", currency: "TND" },
                     activity_template_ids: [ template.id ],
                     custom_activities: [ { name: "Aerial yoga", emoji: "🪂" } ] },
           headers: auth_headers(fresh_admin)

      expect(response).to have_http_status(:created)
      activities = Company.find_by(admin: fresh_admin).activities
      expect(activities.map(&:name)).to contain_exactly("Pilates Reformer", "Aerial yoga")
      expect(activities.find_by(name: "Pilates Reformer").activity_template).to eq(template)
    end

    it "does not open at all when a picked activity is not in the catalogue" do
      post "/api/v1/companies",
           params: { company: { name: "Studio Sousse", timezone: "Africa/Tunis", currency: "TND" },
                     activity_template_ids: [ SecureRandom.uuid ] },
           headers: auth_headers(fresh_admin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(Company.where(admin: fresh_admin)).to be_empty
    end

    it "becomes the admin's active company immediately" do
      post "/api/v1/companies", params: { company: { name: "Iron Box", timezone: "Africa/Tunis", currency: "TND" } },
                                 headers: auth_headers(fresh_admin)

      created = Company.find_by(admin: fresh_admin)
      expect(fresh_admin.reload.active_company).to eq(created)
    end

    it "lets a Pro account open as many salles as it likes" do
      create(:subscription, :pro, company: company)
      create(:company, admin: admin)

      post "/api/v1/companies", params: { company: { name: "Third Gym", timezone: "Africa/Tunis", currency: "TND" } },
                                 headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(admin.companies.count).to eq(3)
    end

    it "refuses a second salle on Starter, and says it comes with Pro" do
      create(:subscription, company: company)

      post "/api/v1/companies", params: { company: { name: "Second Gym", timezone: "Africa/Tunis", currency: "TND" } },
                                 headers: auth_headers(admin)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("multi_salle_not_included")
      expect(admin.companies.count).to eq(1)
      expect(admin.reload.active_company).to eq(company)
    end

    it "lets the free trial open a second salle: it shows the whole product" do
      post "/api/v1/companies", params: { company: { name: "First", timezone: "Africa/Tunis", currency: "TND" } },
                                 headers: auth_headers(fresh_admin)
      expect(fresh_admin.reload.subscription).to be_trial

      post "/api/v1/companies", params: { company: { name: "Second", timezone: "Africa/Tunis", currency: "TND" } },
                                 headers: auth_headers(fresh_admin)

      expect(response).to have_http_status(:created)
      expect(fresh_admin.companies.count).to eq(2)
    end

    it "leaves a Starter account's existing salles alone: only opening another is refused" do
      create(:subscription, company: company)
      second = create(:company, admin: admin)

      post "/api/v1/companies/#{second.id}/switch", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
    end

    it "does not give a later salle a trial of its own: it joins the account's plan" do
      post "/api/v1/companies", params: { company: { name: "First", timezone: "Africa/Tunis", currency: "TND" } },
                                 headers: auth_headers(fresh_admin)
      subscription = fresh_admin.reload.subscription
      subscription.update!(plan: :pro)

      post "/api/v1/companies", params: { company: { name: "Second", timezone: "Africa/Tunis", currency: "TND" } },
                                 headers: auth_headers(fresh_admin)

      expect(response).to have_http_status(:created)
      second = fresh_admin.companies.find_by(name: "Second")
      expect(second.subscription).to eq(subscription)
      expect(subscription.invoices.count).to eq(1)
      expect(second.subscription).to be_pro
    end
  end

  describe "GET /api/v1/companies" do
    it "lists every company this admin runs, flagging which one is active" do
      second = create(:company, admin: admin)

      get "/api/v1/companies", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["companies"]
      expect(body.map { |c| c["id"] }).to contain_exactly(company.id, second.id)
      expect(body.find { |c| c["id"] == company.id }["active"]).to be true
      expect(body.find { |c| c["id"] == second.id }["active"]).to be false
    end

    it "never lists another admin's companies" do
      other = create(:company)

      get "/api/v1/companies", headers: auth_headers(admin)

      ids = response.parsed_body["companies"].map { |c| c["id"] }
      expect(ids).not_to include(other.id)
    end
  end

  describe "POST /api/v1/companies/:id/switch" do
    it "moves the admin's active company and current_company follows on the next request" do
      second = create(:company, admin: admin)

      post "/api/v1/companies/#{second.id}/switch", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["company"]["id"]).to eq(second.id)

      get "/api/v1/company", headers: auth_headers(admin)
      expect(response.parsed_body["company"]["id"]).to eq(second.id)
    end

    it "404s when switching to a company this admin doesn't own" do
      other = create(:company)

      post "/api/v1/companies/#{other.id}/switch", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "still switches while the account is locked" do
      second = create(:company, admin: admin)
      create(:subscription, :closed, company: company)

      post "/api/v1/companies/#{second.id}/switch", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
    end

    it "moves a moderator between the salles they are posted to" do
      second = create(:company, admin: admin)
      record = create(:staff_member, company: company, role: :moderator)
      create(:staff_member, company: second, user: record.user, role: :moderator)

      get "/api/v1/companies", headers: auth_headers(record.user)
      expect(response.parsed_body["companies"].map { |c| c["id"] }).to contain_exactly(company.id, second.id)

      post "/api/v1/companies/#{second.id}/switch", headers: auth_headers(record.user)
      expect(response).to have_http_status(:ok)

      get "/api/v1/bootstrap", headers: auth_headers(record.user)
      expect(response.parsed_body["user"]["company_id"]).to eq(second.id)
    end

    it "404s a moderator switching to a salle of the admin's they are not posted to" do
      second = create(:company, admin: admin)
      record = create(:staff_member, company: company, role: :moderator)

      post "/api/v1/companies/#{second.id}/switch", headers: auth_headers(record.user)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/companies/network" do
    it "lists every salle with its moderators, and every moderator with their salles" do
      second = create(:company, admin: admin, city: "Sousse")
      record = create(:staff_member, company: company, role: :moderator)
      create(:staff_member, company: second, user: record.user, role: :moderator)
      create(:staff_member, company: second, role: :coach)

      get "/api/v1/companies/network", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["companies"].map { |c| c["id"] }).to eq([ company.id, second.id ])
      expect(body["companies"].last["city"]).to eq("Sousse")
      expect(body["companies"].last["moderator_ids"]).to eq([ record.user_id ])
      expect(body["moderators"].map { |m| m["id"] }).to eq([ record.user_id ])
      expect(body["moderators"].first["company_ids"]).to contain_exactly(company.id, second.id)
    end

    it "is the admin's alone" do
      record = create(:staff_member, company: company, role: :moderator)

      get "/api/v1/companies/network", headers: auth_headers(record.user)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PUT /api/v1/companies/:id/moderators" do
    let!(:second) { create(:company, admin: admin) }
    let!(:record) { create(:staff_member, company: company, role: :moderator) }

    it "posts a moderator to another salle, on that salle's own moderator role" do
      put "/api/v1/companies/#{second.id}/moderators", params: { user_ids: [ record.user_id ] }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      post = second.staff_members.find_by(user: record.user)
      expect(post.assigned_role).to eq(second.roles.find_by(key: "moderator"))
      expect(response.parsed_body["companies"].last["moderator_ids"]).to eq([ record.user_id ])
      expect(AuditLog.where(action: "staff.posted", company: second)).to exist
    end

    it "withdraws a moderator from a salle while keeping their others" do
      create(:staff_member, company: second, user: record.user, role: :moderator)

      put "/api/v1/companies/#{second.id}/moderators", params: { user_ids: [] }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(second.staff_members.where(user: record.user)).to be_none
      expect(company.staff_members.where(user: record.user)).to exist
    end

    it "puts a withdrawn moderator back on a salle they still work at" do
      create(:staff_member, company: second, user: record.user, role: :moderator)
      record.user.update!(active_company: second)
      theirs = create(:client, company: company, first_name: "Stays")
      create(:client, company: second, first_name: "Gone")

      put "/api/v1/companies/#{second.id}/moderators", params: { user_ids: [] }, headers: auth_headers(admin)
      get "/api/v1/clients", headers: auth_headers(record.user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["clients"].map { |c| c["id"] }).to eq([ theirs.id ])
    end

    it "refuses to take a moderator off the only salle they work at" do
      put "/api/v1/companies/#{company.id}/moderators", params: { user_ids: [] }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(company.staff_members.where(user: record.user)).to exist
    end

    it "never posts a coach, or someone from another admin's gym" do
      coach = create(:staff_member, company: company, role: :coach)
      stranger = create(:staff_member, role: :moderator)

      [ coach.user_id, stranger.user_id ].each do |id|
        put "/api/v1/companies/#{second.id}/moderators", params: { user_ids: [ id ] }, headers: auth_headers(admin)
        expect(response).to have_http_status(:unprocessable_content)
      end
      expect(second.staff_members.where(coach_id: nil)).to be_none
    end

    it "404s a salle the admin does not run" do
      other = create(:company)

      put "/api/v1/companies/#{other.id}/moderators", params: { user_ids: [ record.user_id ] }, headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "is the admin's alone" do
      put "/api/v1/companies/#{second.id}/moderators", params: { user_ids: [ record.user_id ] }, headers: auth_headers(record.user)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/company — subscription info" do
    it "lists every feature as included and the monthly / annual price in the company's currency" do
      SubscriptionPrice.for("TND", plan: "starter").update!(monthly_cents: 20_000)
      get "/api/v1/company", headers: auth_headers(admin)
      body = response.parsed_body["company"]

      expect(body["included_modules"]).to match_array(ModuleCatalog::KEYS)
      expect(body["monthly_subscription_cents"]).to eq(20_000)
      # 12 months minus the 10% default annual discount
      expect(body["annual_subscription_cents"]).to eq((20_000 * 12 * 0.9).round)
      expect(body["annual_discount_percent"]).to eq(10)
    end

    it "prices in the company's own currency, auto-seeded from the TND reference" do
      SubscriptionPrice.for("TND", plan: "starter").update!(monthly_cents: 18_000)
      company.update!(currency: "EUR")

      get "/api/v1/company", headers: auth_headers(admin)

      expect(response.parsed_body["company"]["monthly_subscription_cents"]).to eq(18_000)
      expect(SubscriptionPrice.for("EUR", plan: "starter").monthly_cents).to eq(18_000)
    end

    it "prices the account's own plan" do
      SubscriptionPrice.for("TND", plan: "pro").update!(monthly_cents: 30_000)
      create(:subscription, :pro, company: company)

      get "/api/v1/company", headers: auth_headers(admin)

      expect(response.parsed_body["company"]["monthly_subscription_cents"]).to eq(30_000)
    end
  end

  describe "PATCH /api/v1/company — branding" do
    it "sets a slug and a primary color" do
      patch "/api/v1/company", params: { company: { slug: "power-gym", primary_color: "#ff5500" } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["company"]
      expect(body["slug"]).to eq("power-gym")
      expect(body["primary_color"]).to eq("#ff5500")
    end

    it "sets the signature contracts are signed with, and who signs them" do
      patch "/api/v1/company",
            params: { company: { signature: fixture_file_upload("sample.png", "image/png"), signatory_name: "Sami, gérant",
                                 contract_terms: "Serviette obligatoire." } },
            headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["company"]
      expect(body["signature_url"]).to be_present
      expect(body).to include("signatory_name" => "Sami, gérant", "contract_terms" => "Serviette obligatoire.")
    end

    it "refuses a signature the PDF could not print" do
      patch "/api/v1/company", params: { company: { signature: fixture_file_upload("sample.txt", "text/plain") } },
                               headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "takes the signature off" do
      company.signature.attach(fixture_file_upload("sample.png", "image/png"))

      patch "/api/v1/company", params: { company: { remove_signature: "true" } }, headers: auth_headers(admin)

      expect(response.parsed_body["company"]["signature_url"]).to be_nil
    end

    it "uploads a logo" do
      patch "/api/v1/company", params: { company: { logo: fixture_file_upload("sample.png", "image/png") } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["company"]["logo_url"]).to be_present
    end

    it "rejects an invalid hex color" do
      patch "/api/v1/company", params: { company: { primary_color: "orange" } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects a slug with uppercase or spaces" do
      patch "/api/v1/company", params: { company: { slug: "Power Gym" } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects a slug already used by another company" do
      create(:company, slug: "power-gym")

      patch "/api/v1/company", params: { company: { slug: "power-gym" } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "defaults working_days to Monday–Friday" do
      get "/api/v1/company", headers: auth_headers(admin)

      expect(response.parsed_body["company"]["working_days"]).to eq([ 1, 2, 3, 4, 5 ])
    end

    it "updates working_days (a Saturday-opening gym)" do
      patch "/api/v1/company", params: { company: { working_days: [ 6, 1, 2, 3, 4 ] } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["company"]["working_days"]).to eq([ 1, 2, 3, 4, 6 ])
      expect(company.reload.working_days).to eq([ 1, 2, 3, 4, 6 ])
    end

    it "rejects an empty working_days list" do
      patch "/api/v1/company", params: { company: { working_days: [ "" ] } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects an out-of-range weekday" do
      patch "/api/v1/company", params: { company: { working_days: [ 1, 2, 7 ] } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "forbids staff from changing branding" do
      staff = create(:staff_member, company: company, role: :moderator)

      patch "/api/v1/company", params: { company: { primary_color: "#ff5500" } }, headers: auth_headers(staff.user)

      expect(response).to have_http_status(:forbidden)
      expect(company.reload.primary_color).to be_nil
    end
  end

  describe "opening hours, now that the company is the place" do
    it "exposes them and lets the admin change them" do
      patch "/api/v1/company", params: { company: { business_hours_start: "07:30", business_hours_end: "21:00" } },
            headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["company"]["business_hours_start"]).to eq("07:30")
      expect(response.parsed_body["company"]["business_hours_end"]).to eq("21:00")
    end
  end
end
