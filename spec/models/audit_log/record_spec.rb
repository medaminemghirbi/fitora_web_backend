require "rails_helper"

RSpec.describe AuditLog, ".record!" do
  it "persists an audit log with the given attributes" do
    company = create(:company)
    user = company.admin
    client = create(:client, company: company)

    audit_log = described_class.record!(
      company: company, user: user, action: "client.created", auditable: client, metadata: { source: "api" }
    )

    expect(audit_log).to be_persisted
    expect(audit_log.company).to eq(company)
    expect(audit_log.user).to eq(user)
    expect(audit_log.action).to eq("client.created")
    expect(audit_log.auditable_type).to eq("Client")
    expect(audit_log.auditable_id).to eq(client.id)
    expect(audit_log.metadata).to eq({ "source" => "api" })
  end

  it "resolves auditable back to the original record" do
    company = create(:company)
    client = create(:client, company: company)

    audit_log = described_class.record!(company: company, user: company.admin, action: "client.updated", auditable: client)

    expect(audit_log.auditable).to eq(client)
  end

  it "defaults metadata to an empty hash when none is given" do
    company = create(:company)
    client = create(:client, company: company)

    audit_log = described_class.record!(company: company, user: company.admin, action: "client.updated", auditable: client)

    expect(audit_log.metadata).to eq({})
  end

  it "allows a nil user for system-initiated actions" do
    company = create(:company)
    client = create(:client, company: company)

    audit_log = described_class.record!(company: company, user: nil, action: "client.synced", auditable: client)

    expect(audit_log).to be_persisted
    expect(audit_log.user).to be_nil
  end

  it "raises when required attributes are missing" do
    company = create(:company)
    client = create(:client, company: company)

    expect do
      described_class.record!(company: company, user: nil, action: nil, auditable: client)
    end.to raise_error(ActiveRecord::RecordInvalid)
  end
end
