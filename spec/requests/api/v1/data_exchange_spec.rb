require "rails_helper"

RSpec.describe "Api::V1::DataExchange", type: :request do
  let(:admin) { create(:user, :admin) }
  # Pro's tool (Subscription#pro_features?); Starter's refusal is below.
  let!(:company) { create(:company, :pro, admin: admin) }

  include ActiveJob::TestHelper

  def upload(csv_body)
    Rack::Test::UploadedFile.new(StringIO.new(csv_body), "text/csv", original_filename: "import.csv")
  end

  # An import is a job now: upload, let DataImportJob run, then read the
  # result back the way the page does.
  def import!(entity, csv)
    perform_enqueued_jobs do
      post "/api/v1/data_exchange/#{entity}/import", params: { file: upload(csv) }, headers: auth_headers(admin)
    end
    expect(response).to have_http_status(:accepted)
    get "/api/v1/data_exchange/imports/#{response.parsed_body['id']}", headers: auth_headers(admin)
  end

  describe "on Starter" do
    it "refuses the template, the export and the import: CSV import / export is Pro's" do
      company.subscription.update!(plan: :starter)

      get "/api/v1/data_exchange/clients/template", headers: auth_headers(admin)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq("pro_required")

      get "/api/v1/data_exchange/clients/export", headers: auth_headers(admin)
      expect(response).to have_http_status(:forbidden)

      post "/api/v1/data_exchange/clients/import", params: { file: upload("first_name\nX\n") }, headers: auth_headers(admin)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET template" do
    it "returns a CSV template with headers and an example row, for a known entity" do
      get "/api/v1/data_exchange/clients/template", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/csv")
      rows = CSV.parse(response.body)
      expect(rows.first).to eq(%w[first_name last_name email phone])
      expect(rows.size).to eq(2)
    end

    it "404s for an unknown entity" do
      get "/api/v1/data_exchange/spaceships/template", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "forbids a staff member without the matching capability" do
      staff = create(:staff_member, company: company, role: :moderator,
                     assigned_role: create(:role, company: company, permissions: []))

      get "/api/v1/data_exchange/clients/template", headers: auth_headers(staff.user)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET export" do
    it "exports the company's clients as CSV" do
      create(:client, company: company, first_name: "Rania", last_name: "Ferjani", email: "rania@example.com", phone: "+21620000001")

      get "/api/v1/data_exchange/clients/export", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      rows = CSV.parse(response.body, headers: true)
      expect(rows.first["email"]).to eq("rania@example.com")
    end

    it "exports the company's activities as CSV" do
      create(:activity, company: company, name: "Yoga")

      get "/api/v1/data_exchange/activities/export", headers: auth_headers(admin)

      rows = CSV.parse(response.body, headers: true)
      expect(rows.first["name"]).to eq("Yoga")
    end

    it "exports the company's contracts as CSV" do
      client = create(:client, company: company)
      contract_type = create(:contract_type, company: company, name: "Mensuel")
      activity = create(:activity, company: company, name: "Yoga")
      create(:contract, client: client, contract_type: contract_type, company: company, activity: activity)

      get "/api/v1/data_exchange/contracts/export", headers: auth_headers(admin)

      rows = CSV.parse(response.body, headers: true)
      expect(rows.first["client_email"]).to eq(client.email)
      expect(rows.first["contract_type_name"]).to eq("Mensuel")
      expect(rows.first["activity_name"]).to eq("Yoga")
    end

    it "exports the company's payments as CSV" do
      client = create(:client, company: company)
      contract = create(:contract, client: client, contract_type: create(:contract_type, company: company))
      create(:payment, client: client, company: company, contract: contract, amount: 90)

      get "/api/v1/data_exchange/payments/export", headers: auth_headers(admin)

      rows = CSV.parse(response.body, headers: true)
      expect(rows.first["client_email"]).to eq(client.email)
      expect(rows.first["amount"].to_f).to eq(90.0)
    end
  end

  describe "POST import" do
    context "clients" do
      it "creates clients from valid rows and reports invalid ones" do
        csv = <<~CSV
          first_name,last_name,email,phone
          Rania,Ferjani,rania@example.com,+21620000001
          ,MissingFirstName,bad@example.com,+21620000002
        CSV

        import!("clients", csv)

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["created"]).to eq(1)
        expect(body["errors"].size).to eq(1)
        expect(body["errors"].first["row"]).to eq(3)
        expect(company.clients.find_by(email: "rania@example.com")).to be_present
      end

      it "requires a file" do
        post "/api/v1/data_exchange/clients/import", headers: auth_headers(admin)

        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    context "activities" do
      it "creates an activity for the company's company" do
        csv = "name,session_format,duration_minutes,capacity,emoji,description\nYoga,collective,60,20,🧘,\n"

        import!("activities", csv)

        expect(response.parsed_body["created"]).to eq(1)
        expect(company.activities.find_by(name: "Yoga")).to be_present
      end
    end

    context "contracts" do
      it "creates a contract when the client, plan, and activity all exist" do
        client = create(:client, company: company, email: "amine@example.com")
        yoga = create(:activity, company: company, name: "Yoga")
        create(:contract_type, company: company, name: "Abonnement mensuel", activity: yoga)
        csv = "client_email,contract_type_name,activity_name,starts_at\namine@example.com,Abonnement mensuel,Yoga,2026-01-01\n"

        import!("contracts", csv)

        expect(response.parsed_body["created"]).to eq(1)
        expect(client.contracts.count).to eq(1)
      end

      it "reports a row whose client email doesn't exist" do
        create(:contract_type, company: company, name: "Abonnement mensuel")
        create(:activity, company: company, name: "Yoga")
        csv = "client_email,contract_type_name,activity_name,starts_at\nghost@example.com,Abonnement mensuel,Yoga,2026-01-01\n"

        import!("contracts", csv)

        body = response.parsed_body
        expect(body["created"]).to eq(0)
        expect(body["errors"].first["message"]).to include("ghost@example.com")
      end

      it "reports a row whose activity doesn't exist" do
        create(:client, company: company, email: "amine@example.com")
        create(:contract_type, company: company, name: "Abonnement mensuel")
        csv = "client_email,contract_type_name,activity_name,starts_at\namine@example.com,Abonnement mensuel,Ghost Activity,2026-01-01\n"

        import!("contracts", csv)

        body = response.parsed_body
        expect(body["created"]).to eq(0)
        expect(body["errors"].first["message"]).to include("Ghost Activity")
      end
    end

    context "payments" do
      it "records a payment against the client's current contract" do
        client = create(:client, company: company, email: "amine@example.com")
        create(:contract, client: client, contract_type: create(:contract_type, company: company))
        csv = "client_email,amount,payment_method,paid_at\namine@example.com,90,cash,2026-01-01\n"

        import!("payments", csv)

        expect(response.parsed_body["created"]).to eq(1)
        expect(client.payments.count).to eq(1)
      end

      it "reports a row for a client with no active contract" do
        create(:client, company: company, email: "amine@example.com")
        csv = "client_email,amount,payment_method,paid_at\namine@example.com,90,cash,2026-01-01\n"

        import!("payments", csv)

        body = response.parsed_body
        expect(body["created"]).to eq(0)
        expect(body["errors"].first["message"]).to include("no active contract")
      end
    end
  end

  describe "import limits" do
    it "refuses a file over the size limit before storing it" do
      stub_const("DataImport::MAX_BYTES", 10)
      post "/api/v1/data_exchange/clients/import", params: { file: upload("first_name,last_name\nA,B\n") }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "fails an import with more rows than one import takes, and says so" do
      stub_const("DataImport::MAX_ROWS", 1)
      import!("clients", "first_name,last_name,email,phone\nA,B,,1\nC,D,,2\n")

      expect(response.parsed_body["status"]).to eq("failed")
      expect(response.parsed_body["message"]).to include("Split the file")
      expect(company.clients.count).to eq(0)
    end

    it "reports a malformed file as a failed import" do
      import!("clients", "first_name,last_name\n\"unclosed,B\n")

      expect(response.parsed_body["status"]).to eq("failed")
    end

    it "keeps another gym's imports out of reach" do
      import!("clients", "first_name,last_name,email,phone\nA,B,,1\n")
      id = DataImport.last.id

      get "/api/v1/data_exchange/imports/#{id}", headers: auth_headers(create(:company, :pro).admin)
      expect(response).to have_http_status(:not_found)
    end
  end
end
