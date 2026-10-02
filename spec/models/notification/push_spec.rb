require "rails_helper"

RSpec.describe Notification, ".push" do
  let(:company) { create(:company) }
  let(:admin) { company.admin }

  def push(dedup: "contract_exp:1")
    described_class.push(
      recipient: admin, kind: "contract_expiring", data: { "title" => "X" },
      url: "/admin/x", dedup_key: dedup
    )
  end

  it "creates a notification for the recipient" do
    expect { push }.to change(admin.notifications, :count).by(1)
  end

  it "is idempotent on the dedup key" do
    push
    expect { push }.not_to change(Notification, :count)
  end

  it "returns nil when the recipient is nil" do
    expect(described_class.push(recipient: nil, kind: "x", data: {}, url: "/", dedup_key: "k")).to be_nil
  end
end
