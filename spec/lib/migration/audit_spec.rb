require "rails_helper"

RSpec.describe Migration::Audit do
  def findings(result)
    result[:findings].index_by(&:check)
  end

  it "passes on a database at the target schema" do
    result = described_class.call

    failed = result[:findings].reject(&:ok?)
    expect(failed.map(&:check)).to be_empty
    expect(result[:ok]).to be(true)
  end

  it "counts the tables the migrations touch and nothing it cannot find" do
    counts = described_class.new.row_counts

    expect(counts.keys).to include("companies", "clients", "spaces", "bookings")
    expect(counts.keys).to all(satisfy { |t| ActiveRecord::Base.connection.tables.include?(t) })
  end

  it "reports a table that lost rows since the snapshot" do
    result = described_class.call(before: { "clients" => Client.count + 5 })

    expect(findings(result)["row counts"]).not_to be_ok
    expect(result[:ok]).to be(false)
  end

  it "accepts a table that grew — a rehearsal on a live copy picks up writes" do
    create(:client)
    result = described_class.call(before: { "clients" => Client.count - 1 })

    expect(findings(result)["row counts"]).to be_ok
  end

  # The check the whole audit exists for: a foreign key cannot tell that a
  # row reaches into another company, and a migration that rewrote a
  # reference is exactly where that would happen.
  it "catches a session scheduled on another company's activity" do
    session = create(:session)
    session.update_columns(activity_id: create(:activity, company: create(:company)).id)

    result = described_class.call

    expect(findings(result)["sessions use their own company's activity"]).not_to be_ok
  end

  it "catches a booking by someone who is not a member of that gym" do
    booking = create(:booking)
    booking.client.memberships.delete_all

    result = described_class.call

    expect(findings(result)["bookings belong to a member of that gym"]).not_to be_ok
  end

  it "catches a company whose opening hours never made it into settings" do
    create(:company).update_column(:settings, { "features" => { "spaces" => true } })

    result = described_class.call

    expect(findings(result)["settings backfilled"]).not_to be_ok
  end

  it "catches a key the configuration does not declare" do
    create(:company).update_column(:settings, CompanySettings.default.to_h.merge("billing" => {}))

    result = described_class.call

    expect(findings(result)["settings has no stray sections"]).not_to be_ok
  end
end
