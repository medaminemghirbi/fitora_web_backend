require "rails_helper"

# A list page should cost the same number of queries for 2 rows as for 6.
# Each of these used to grow with every row — the members page by nine
# queries a member — which only shows once a gym has real traffic. Bullet
# cannot see most of them (a `find_by` per row is not an association load),
# so this counts.
RSpec.describe "List pages do not query per row", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin) }
  let(:activity) { create(:activity, company: company) }
  let(:plan) { create(:contract_type, company: company, activity: activity) }

  def add_rows(count)
    count.times do |i|
      member = create(:client, company: company)
      contract = create(:contract, client: member, contract_type: plan, activity: activity)
      session = create(:session, activity: activity, starts_at: (i + 1).days.from_now.change(hour: 10))
      create(:booking, client: member, session: session)
      create(:payment, client: member, contract: contract)
      create(:coach, company: company)
      create(:staff_member, company: company, role: :moderator)
    end
  end

  def queries_for(path)
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get path, headers: auth_headers(admin) }
    expect(response).to have_http_status(:ok)
    count
  end

  %w[
    /api/v1/clients /api/v1/contracts /api/v1/payments /api/v1/bookings
    /api/v1/sessions /api/v1/staff /api/v1/coaches
  ].each do |path|
    it "GET #{path}" do
      add_rows(2)
      few = queries_for(path)
      add_rows(4)
      many = queries_for(path)

      expect(many).to eq(few), "#{path}: #{few} queries for 2 rows, #{many} for 6"
    end
  end
end
