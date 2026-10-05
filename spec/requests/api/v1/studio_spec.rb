require "rails_helper"

# What a private studio (EMS, Pilates, yoga, personal training) runs on:
# open one-to-one slots members book themselves, a trial or single session
# sold at the desk, carnets with a lifetime of their own, memberships put on
# hold, and the health file a coach reads before a session.
RSpec.describe "A private studio", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, :pro, admin: admin) }
  let(:ems) { create(:activity, company: company, name: "EMS", session_format: :individual, capacity: 1, duration: 25) }
  let(:prospect) { create(:client, company: company) }

  def slot(at: 2.days.from_now.change(hour: 9), **attrs)
    create(:session, company: company, activity: ems, capacity: 1, price: 40,
                     starts_at: at, ends_at: at + 25.minutes, **attrs)
  end

  describe "POST /api/v1/bookings with a trial or a drop-in" do
    it "books a free trial for someone with no contract" do
      post "/api/v1/bookings", params: { client_id: prospect.id, session_id: slot.id, trial: true },
                               headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      booking = response.parsed_body["booking"]
      expect(booking["trial"]).to be(true)
      expect(booking["amount"].to_f).to eq(0)
      expect(booking["covered_by"]).to eq("type" => "trial")
    end

    it "books a single session to pay, at the session's price" do
      post "/api/v1/bookings", params: { client_id: prospect.id, session_id: slot.id, drop_in: true },
                               headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      booking = response.parsed_body["booking"]
      expect(booking["amount"].to_f).to eq(40)
      expect(booking["payment_status"]).to eq("unpaid")
      expect(booking["covered_by"]).to eq("type" => "drop_in")
    end

    it "still refuses someone with no contract when neither was asked for" do
      post "/api/v1/bookings", params: { client_id: prospect.id, session_id: slot.id }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/v1/sessions for a one-to-one activity" do
    let(:at) { 3.days.from_now.change(hour: 10) }

    it "opens a slot with nobody in it, for a member to take from their app" do
      post "/api/v1/sessions",
           params: { session: { activity_id: ems.id, starts_at: at.iso8601, ends_at: (at + 25.minutes).iso8601 } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(Session.find(response.parsed_body["session"]["id"]).bookings).to be_empty
    end

    it "books a prospect's trial into the slot it creates" do
      post "/api/v1/sessions",
           params: { session: { activity_id: ems.id, client_id: prospect.id, trial: true,
                                starts_at: at.iso8601, ends_at: (at + 25.minutes).iso8601 } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      booking = Session.find(response.parsed_body["session"]["id"]).bookings.sole
      expect(booking.trial).to be(true)
    end
  end

  describe "GET /api/v1/me/sessions" do
    let(:member) { create(:client, company: company, password: "password123") }

    it "shows open one-to-one slots, and hides one somebody else has taken" do
      open_slot = slot
      taken = slot(at: 2.days.from_now.change(hour: 11))
      taken.book!(prospect, trial: true)

      get "/api/v1/me/sessions", headers: auth_headers(member)

      sessions = response.parsed_body["sessions"]
      expect(sessions.map { |s| s["id"] }).to eq([ open_slot.id ])
      expect(sessions.first["individual"]).to be(true)
    end

    it "keeps showing the member their own appointment" do
      mine = slot
      plan = create(:contract_type, company: company, activity: ems)
      create(:contract, client: member, contract_type: plan, company: company, activity: ems)
      mine.book!(member)

      get "/api/v1/me/sessions", headers: auth_headers(member)

      expect(response.parsed_body["sessions"].map { |s| s["already_booked"] }).to eq([ true ])
    end
  end

  describe "POST /api/v1/contracts/:id/pause and /resume" do
    let(:plan) { create(:contract_type, company: company, activity: ems) }
    let(:contract) do
      create(:contract, client: prospect, contract_type: plan, company: company, activity: ems,
                        starts_at: 5.days.ago, expires_at: 25.days.from_now)
    end

    it "puts a membership on hold and gives the time back on resume" do
      post "/api/v1/contracts/#{contract.id}/pause", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["contract"]["paused"]).to be(true)
      expect(AuditLog.where(action: "contract.paused")).to exist

      travel 10.days do
        post "/api/v1/contracts/#{contract.id}/resume", headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["contract"]["paused"]).to be(false)
        expect(contract.reload.expires_at.to_date).to eq(35.days.from_now.to_date - 10)
      end
    end

    it "lists paused memberships on their own filter" do
      contract.pause!

      get "/api/v1/contracts", params: { status: "paused" }, headers: auth_headers(admin)

      expect(response.parsed_body["contracts"].map { |c| c["id"] }).to eq([ contract.id ])
      expect(response.parsed_body["counts"]["paused"]).to eq(1)
    end

    it "refuses to resume a membership that is not paused" do
      post "/api/v1/contracts/#{contract.id}/resume", headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/v1/contract_types with a custom validity" do
    it "sells a carnet that lasts its own number of days" do
      post "/api/v1/contract_types",
           params: { contract_type: { name: "10 séances", billing_period: "custom", validity_days: 56, booking_limit: 10 } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      plan = response.parsed_body["plan"] || response.parsed_body["contract_type"]
      expect(plan["validity_days"]).to eq(56)
      expect(plan["duration_days"]).to eq(56)
    end

    it "refuses a custom period with no validity" do
      post "/api/v1/contract_types",
           params: { contract_type: { name: "10 séances", billing_period: "custom" } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/v1/recurring_schedules in a cabin" do
    let(:cabin) { create(:space, company: company, name: "Cabine 1") }

    before { company.update!(settings: { features: { spaces: true } }) }

    it "puts every generated slot in the cabin" do
      post "/api/v1/recurring_schedules",
           params: { recurring_schedule: { activity_id: ems.id, space_id: cabin.id, weekdays: [ 1, 3 ], start_time: "09:00",
                                           recurrence_type: "weekly", starts_on: Date.current, ends_on: 14.days.from_now.to_date } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["recurring_schedule"]["space_name"]).to eq("Cabine 1")
      expect(Session.where(space: cabin).count).to be_positive
    end

    it "refuses another gym's cabin" do
      foreign = create(:space, company: create(:company))

      post "/api/v1/recurring_schedules",
           params: { recurring_schedule: { activity_id: ems.id, space_id: foreign.id, weekdays: [ 1 ], start_time: "09:00",
                                           recurrence_type: "weekly", starts_on: Date.current, ends_on: 14.days.from_now.to_date } },
           headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH /api/v1/clients/:id with the health file" do
    it "keeps contraindications and the waiver date on this gym's own membership" do
      patch "/api/v1/clients/#{prospect.id}",
            params: { client: { health_notes: "Pacemaker", waiver_signed_on: "2026-10-01" } },
            headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      membership = prospect.membership_for(company)
      expect(membership.health_notes).to eq("Pacemaker")
      expect(membership.waiver_signed_on).to eq(Date.new(2026, 10, 1))

      get "/api/v1/clients/#{prospect.id}", headers: auth_headers(admin)
      expect(response.parsed_body["client"]["health_notes"]).to eq("Pacemaker")
    end
  end

  describe "packs, for a studio that never turned them on" do
    it "lists none and refuses to build one" do
      get "/api/v1/packs", headers: auth_headers(admin)
      expect(response.parsed_body["packs"]).to eq([])

      post "/api/v1/packs", params: { pack: { name: "Duo" } }, headers: auth_headers(admin)
      expect(response).to have_http_status(:not_found)
    end
  end
end
