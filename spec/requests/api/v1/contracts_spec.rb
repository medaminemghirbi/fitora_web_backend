require "rails_helper"

RSpec.describe "Api::V1::Contracts", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:company) { create(:company, admin: admin) }

  describe "company isolation" do
    it "never exposes another company's contracts to an admin" do
      create(:subscription, company: company)

      other_org = create(:company)
      other_plan = create(:contract_type, company: other_org)
      create(:contract, contract_type: other_plan)

      get "/api/v1/contracts", headers: auth_headers(admin)

      expect(response.parsed_body["contracts"]).to eq([])
    end
  end

  describe "GET /api/v1/contracts" do
    it "filters by contract_type_id" do
      premium = create(:contract_type, company: company, name: "Premium")
      basic = create(:contract_type, company: company, name: "Basic")
      premium_contract = create(:contract, contract_type: premium, company: company)
      create(:contract, contract_type: basic, company: company)

      get "/api/v1/contracts", params: { contract_type_id: premium.id }, headers: auth_headers(admin)

      ids = response.parsed_body["contracts"].map { |c| c["id"] }
      expect(ids).to eq([ premium_contract.id ])
    end

    it "filters by ?q= on client name or plan name" do
      premium = create(:contract_type, company: company, name: "Premium")
      basic = create(:contract_type, company: company, name: "Basic")
      hit = create(:contract, contract_type: premium, company: company,
                   client: create(:client, company: company, first_name: "Mariem", last_name: "Sassi"))
      create(:contract, contract_type: basic, company: company,
             client: create(:client, company: company, first_name: "Karim", last_name: "Ben Youssef"))

      get "/api/v1/contracts", params: { q: "mariem" }, headers: auth_headers(admin)
      expect(response.parsed_body["contracts"].map { |c| c["id"] }).to eq([ hit.id ])

      get "/api/v1/contracts", params: { q: "premium" }, headers: auth_headers(admin)
      expect(response.parsed_body["contracts"].map { |c| c["id"] }).to eq([ hit.id ])
    end
  end

  describe "POST /api/v1/contracts" do
    it "lets the admin give a client a contract, active immediately" do
      activity = create(:activity, company: company)
      plan = create(:contract_type, company: company, active: true, activity: activity, price: 89)
      client = create(:client, company: company)

      post "/api/v1/contracts",
           params: { client_id: client.id, contract_type_id: plan.id, activity_id: activity.id, collect_payment: "true", payment_method: "cash" },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["contract"]["status"]).to eq("active")
      expect(response.parsed_body["contract"]["payment_status"]).to eq("paid")
      expect(response.parsed_body["contract"]["activity"]["id"]).to eq(activity.id)
      expect(response.parsed_body["payment"]["status"]).to eq("paid")
    end

    it "creates the contract unpaid when no payment is recorded" do
      activity = create(:activity, company: company)
      plan = create(:contract_type, company: company, active: true, activity: activity)
      client = create(:client, company: company)

      post "/api/v1/contracts", params: { client_id: client.id, contract_type_id: plan.id, activity_id: activity.id }, headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["contract"]["payment_status"]).to eq("unpaid")
      expect(response.parsed_body["payment"]).to be_nil
    end

    it "404s when activity_id is missing" do
      plan = create(:contract_type, company: company, active: true)
      client = create(:client, company: company)

      post "/api/v1/contracts", params: { client_id: client.id, contract_type_id: plan.id }, headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body["error"]).to eq("Activity not found")
    end

    it "404s for an activity that belongs to another company" do
      plan = create(:contract_type, company: company, active: true)
      client = create(:client, company: company)
      other_activity = create(:activity, company: create(:company))

      post "/api/v1/contracts", params: { client_id: client.id, contract_type_id: plan.id, activity_id: other_activity.id }, headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
    end

    it "forbids a coach from giving a client a contract" do
      activity = create(:activity, company: company)
      plan = create(:contract_type, company: company, active: true, activity: activity)
      client = create(:client, company: company)
      coach = create(:staff_member, company: company, role: :coach)

      post "/api/v1/contracts", params: { client_id: client.id, contract_type_id: plan.id, activity_id: activity.id }, headers: auth_headers(coach.user)

      expect(response).to have_http_status(:forbidden)
    end

    it "logs an audit entry for the new contract" do
      activity = create(:activity, company: company)
      plan = create(:contract_type, company: company, active: true, activity: activity)
      client = create(:client, company: company)

      post "/api/v1/contracts", params: { client_id: client.id, contract_type_id: plan.id, activity_id: activity.id }, headers: auth_headers(admin)

      log = AuditLog.last
      expect(log.action).to eq("contract.created")
      expect(log.company_id).to eq(company.id)
    end
  end

  describe "PATCH /api/v1/contracts/:id" do
    it "moves the start date and re-derives the end date from the plan" do
      plan = create(:contract_type, company: company, billing_period: :monthly)
      client = create(:client, company: company)
      contract = create(:contract, client: client, contract_type: plan, company: company)

      patch "/api/v1/contracts/#{contract.id}", params: { starts_on: "2026-10-01" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      period = contract.current_period.reload
      # Dates are the gym's: 1 October starts at midnight in Tunis.
      zone = company.time_zone
      expect(period.starts_at.in_time_zone(zone).to_date.to_s).to eq("2026-10-01")
      expect(period.expires_at.in_time_zone(zone).to_date.to_s).to eq("2026-10-31")
    end

    it "changes the discount while unpaid and recomputes the price" do
      plan = create(:contract_type, company: company, price: 100)
      client = create(:client, company: company)
      contract = create(:contract, client: client, contract_type: plan, company: company, payment_status: :unpaid)

      patch "/api/v1/contracts/#{contract.id}", params: { discount: 25 }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["contract"]["final_price"]).to eq("75.0")
    end

    it "refuses to change the discount once the abonnement is paid" do
      plan = create(:contract_type, company: company, price: 100)
      client = create(:client, company: company)
      contract = create(:contract, client: client, contract_type: plan, company: company, payment_status: :paid)

      patch "/api/v1/contracts/#{contract.id}", params: { discount: 25 }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/v1/contracts/:id/renew" do
    it "adds a new period to the same contract, without touching history" do
      plan = create(:contract_type, company: company)
      client = create(:client, company: company)
      original = create(:contract, client: client, contract_type: plan, company: company,
                                      starts_at: 30.days.ago, expires_at: 1.day.from_now)
      original_period = original.current_period

      post "/api/v1/contracts/#{original.id}/renew", headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      renewed = response.parsed_body["contract"]
      expect(renewed["id"]).to eq(original.id)
      expect(client.contracts.count).to eq(1)
      expect(original.contract_periods.count).to eq(2)
      expect(original_period.reload.status).to eq("active") # history untouched
    end
  end

  describe "POST /api/v1/contracts/:id/cancel" do
    it "marks the contract cancelled" do
      plan = create(:contract_type, company: company)
      client = create(:client, company: company)
      contract = create(:contract, client: client, contract_type: plan, company: company, status: :active)

      post "/api/v1/contracts/#{contract.id}/cancel", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["contract"]["status"]).to eq("cancelled")
      expect(contract.reload).to be_cancelled
    end

    it "rejects cancelling an already-cancelled contract" do
      plan = create(:contract_type, company: company)
      client = create(:client, company: company)
      contract = create(:contract, client: client, contract_type: plan, company: company, status: :cancelled)

      post "/api/v1/contracts/#{contract.id}/cancel", headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "forbids a coach — coaches don't have the contracts capability" do
      plan = create(:contract_type, company: company)
      client = create(:client, company: company)
      contract = create(:contract, client: client, contract_type: plan, company: company, status: :active)
      coach = create(:staff_member, company: company, role: :coach)

      post "/api/v1/contracts/#{contract.id}/cancel", headers: auth_headers(coach.user)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "DELETE /api/v1/contracts/:id" do
    it "deletes a cancelled contract" do
      plan = create(:contract_type, company: company)
      client = create(:client, company: company)
      contract = create(:contract, client: client, contract_type: plan, company: company, status: :cancelled)

      delete "/api/v1/contracts/#{contract.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:no_content)
      expect(Contract.exists?(contract.id)).to be false
    end

    it "refuses to delete a contract that isn't cancelled" do
      plan = create(:contract_type, company: company)
      client = create(:client, company: company)
      contract = create(:contract, client: client, contract_type: plan, company: company, status: :active)

      delete "/api/v1/contracts/#{contract.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(Contract.exists?(contract.id)).to be true
    end

    it "nullifies, rather than deletes, payments and bookings recorded against it" do
      plan = create(:contract_type, company: company)
      client = create(:client, company: company)
      contract = create(:contract, client: client, contract_type: plan, company: company, status: :cancelled)
      payment = create(:payment, company: company, client: client, contract_period: contract.current_period)
      session = create(:session, capacity: 5)
      booking = create(:booking, client: client, session: session, contract_period: contract.current_period)

      delete "/api/v1/contracts/#{contract.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:no_content)
      expect(payment.reload.contract_period_id).to be_nil
      expect(booking.reload.contract_period_id).to be_nil
    end

    it "forbids a coach — coaches don't have the contracts capability" do
      plan = create(:contract_type, company: company)
      client = create(:client, company: company)
      contract = create(:contract, client: client, contract_type: plan, company: company, status: :cancelled)
      coach = create(:staff_member, company: company, role: :coach)

      delete "/api/v1/contracts/#{contract.id}", headers: auth_headers(coach.user)

      expect(response).to have_http_status(:forbidden)
      expect(Contract.exists?(contract.id)).to be true
    end
  end

  describe "GET /api/v1/contracts/:id/receipt" do
    let(:plan) { create(:contract_type, company: company, price: 89) }
    let(:client) { create(:client, company: company) }
    let(:contract) { create(:contract, client: client, contract_type: plan, company: company) }

    it "returns a PDF" do
      create(:payment, company: company, client: client, contract_period: contract.current_period, amount: 89, status: :paid)

      get "/api/v1/contracts/#{contract.id}/receipt", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to eq("application/pdf")
      expect(response.headers["Content-Disposition"]).to include("recu-")
      expect(response.body.byteslice(0, 4)).to eq("%PDF")
    end

    it "still returns a PDF when nothing has been paid yet" do
      get "/api/v1/contracts/#{contract.id}/receipt", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.body.byteslice(0, 4)).to eq("%PDF")
    end

    it "is available to staff who can see contracts, not just the admin" do
      moderator = create(:staff_member, company: company, role: :moderator)

      get "/api/v1/contracts/#{contract.id}/receipt", headers: auth_headers(moderator.user)

      expect(response).to have_http_status(:ok)
    end

    it "forbids a coach, who has no contracts capability" do
      coach = create(:staff_member, company: company, role: :coach)

      get "/api/v1/contracts/#{contract.id}/receipt", headers: auth_headers(coach.user)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "the list's rail counts and portfolio totals" do
    it "counts each status on the current period, and values the portfolio at the prices sold" do
      activity = create(:activity, company: company)
      plan = create(:contract_type, company: company, activity: activity, price: 250)
      create(:contract, company: company, contract_type: plan, activity: activity,
             client: create(:client, company: company), status: :active, discount: 50)
      create(:contract, company: company, contract_type: plan, activity: activity,
             client: create(:client, company: company), status: :expired)

      get "/api/v1/contracts", headers: auth_headers(admin)

      body = response.parsed_body
      expect(body["counts"]["all"]).to eq(2)
      expect(body["counts"]["active"]).to eq(1)
      expect(body["counts"]["expired"]).to eq(1)
      # 250 sold minus the 50 discount — the frozen period price, not the plan's.
      expect(body["totals"]["portfolio_value"]).to eq(200.0)
      expect(body["totals"]["average_basket"]).to eq(200.0)
      expect(body["plan_counts"][plan.id]).to eq(2)
    end

    it "counts the active contracts still unpaid" do
      activity = create(:activity, company: company)
      plan = create(:contract_type, company: company, activity: activity, price: 100)
      create(:contract, company: company, contract_type: plan, activity: activity,
             client: create(:client, company: company), status: :active, payment_status: :unpaid)
      create(:contract, company: company, contract_type: plan, activity: activity,
             client: create(:client, company: company), status: :active, payment_status: :paid)

      get "/api/v1/contracts", headers: auth_headers(admin)

      expect(response.parsed_body["counts"]["unpaid"]).to eq(1)
      expect(response.parsed_body["totals"]["unpaid_value"]).to eq(100.0)
    end
  end

  describe "GET /api/v1/contracts — the filters the dashboard links to" do
    let(:plan) { create(:contract_type, company: company) }

    it "status=expiring returns only live contracts running out within the month" do
      soon = create(:contract, client: create(:client, company: company), contract_type: plan)
      soon.current_period.update!(status: :active, expires_at: 10.days.from_now)

      later = create(:contract, client: create(:client, company: company), contract_type: plan)
      later.current_period.update!(status: :active, expires_at: 90.days.from_now)

      gone = create(:contract, client: create(:client, company: company), contract_type: plan)
      gone.current_period.update!(status: :expired, expires_at: 1.day.ago)

      get "/api/v1/contracts", params: { status: "expiring" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["contracts"].map { |c| c["id"] }).to eq([ soon.id ])
    end

    it "payment=unpaid returns live contracts nobody has paid for" do
      owing = create(:contract, client: create(:client, company: company), contract_type: plan)
      owing.current_period.update!(status: :active, payment_status: :unpaid, expires_at: 90.days.from_now)

      settled = create(:contract, client: create(:client, company: company), contract_type: plan)
      settled.current_period.update!(status: :active, payment_status: :paid, expires_at: 90.days.from_now)

      get "/api/v1/contracts", params: { payment: "unpaid" }, headers: auth_headers(admin)

      expect(response.parsed_body["contracts"].map { |c| c["id"] }).to eq([ owing.id ])
    end

    # Renewing early adds a period, it never rewrites the running one — so
    # the list has to stop calling the contract "à renouveler" while still
    # asking for the renewal's money.
    it "drops a contract from expiring once a renewal is queued behind it" do
      renewed = create(:contract, client: create(:client, company: company), contract_type: plan)
      renewed.current_period.update!(status: :active, expires_at: 10.days.from_now, payment_status: :paid)
      renewed.renew!

      still_running_out = create(:contract, client: create(:client, company: company), contract_type: plan)
      still_running_out.current_period.update!(status: :active, expires_at: 10.days.from_now)

      get "/api/v1/contracts", params: { status: "expiring" }, headers: auth_headers(admin)

      expect(response.parsed_body["contracts"].map { |c| c["id"] }).to eq([ still_running_out.id ])
      expect(response.parsed_body["counts"]["expiring"]).to eq(1)
    end

    it "still asks for the money on a queued renewal, on top of the running term" do
      renewed = create(:contract, client: create(:client, company: company), contract_type: plan)
      renewed.current_period.update!(status: :active, expires_at: 10.days.from_now, payment_status: :paid)
      renewed.renew!
      queued = renewed.reload.next_period

      get "/api/v1/contracts", params: { payment: "unpaid" }, headers: auth_headers(admin)

      body = response.parsed_body
      expect(body["contracts"].map { |c| c["id"] }).to include(renewed.id)

      row = body["contracts"].find { |c| c["id"] == renewed.id }
      # The badge still describes the term in force — it is paid — while the
      # money owed and the period to collect point at the renewal.
      expect(row["payment_status"]).to eq("paid")
      expect(row["amount_due"]).to eq(queued.final_price.to_f)
      expect(row["payable_period_id"]).to eq(queued.id)
    end
  end
end
