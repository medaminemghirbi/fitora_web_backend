require "rails_helper"

RSpec.describe AttendanceRecord, ".mark!" do
  it "creates an attendance record for a booking" do
    booking = create(:booking, status: :confirmed)
    coach_user = create(:user)

    record = described_class.mark!(booking: booking, status: :present, marked_by: coach_user)

    expect(record).to be_persisted
    expect(record.marked_by).to eq(coach_user)
    expect(record.checked_in_at).to be_nil
  end

  it "is idempotent — marking the same booking twice updates the one record instead of erroring" do
    booking = create(:booking, status: :confirmed)
    marker = create(:user)

    first = described_class.mark!(booking: booking, status: :present, marked_by: marker)
    second = described_class.mark!(booking: booking, status: :absent, marked_by: marker)

    expect(second.id).to eq(first.id)
    expect(AttendanceRecord.where(booking: booking).count).to eq(1)
    expect(AttendanceRecord.find_by(booking: booking).status).to eq("absent")
  end

  it "records checked_in_at for a check-in style mark" do
    booking = create(:booking, status: :confirmed)
    marker = create(:user)

    travel_to Time.zone.parse("2026-01-10 09:00:00") do
      record = described_class.mark!(booking: booking, status: :present, marked_by: marker, checked_in_at: Time.current)

      expect(record.checked_in_at).to eq(Time.current)
    end
  end
end
