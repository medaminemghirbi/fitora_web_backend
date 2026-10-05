require "rails_helper"

RSpec.describe Notifications::SendSessionRemindersJob do
  let(:company) { create(:company) }
  let(:activity) { create(:activity, company: company) }
  let(:member) { create(:client, company: company, password: "password123") }
  let(:plan) { create(:contract_type, company: company, activity: activity) }

  before { create(:contract, client: member, contract_type: plan, company: company, activity: activity) }

  def session_in(hours)
    create(:session, company: company, activity: activity,
                     starts_at: hours.hours.from_now, ends_at: hours.hours.from_now + 1.hour)
  end

  # Booked well ahead, so the reminder window has not swallowed the booking.
  def booked(session)
    booking = session.book!(member)
    booking.update_columns(created_at: 5.days.ago) # rubocop:disable Rails/SkipsModelValidations
    booking
  end

  it "reminds a member of a session inside the gym's window, once" do
    booking = booked(session_in(20))

    expect { described_class.perform_now }.to change { member.notifications.where(kind: "session_reminder").count }.by(1)
    expect(booking.reload.reminder_sent_at).to be_present
    expect { described_class.perform_now }.not_to(change { member.notifications.count })
  end

  it "leaves a session beyond the window for later" do
    booking = booked(session_in(30))

    described_class.perform_now

    expect(booking.reload.reminder_sent_at).to be_nil
  end

  it "follows the gym's own window" do
    company.update!(settings: { booking: { reminder_hours: 48 } })
    booking = booked(session_in(30))

    described_class.perform_now

    expect(booking.reload.reminder_sent_at).to be_present
  end

  it "sends nothing when the gym turned reminders off" do
    company.update!(settings: { booking: { reminder_hours: 0 } })
    booking = booked(session_in(5))

    described_class.perform_now

    expect(booking.reload.reminder_sent_at).to be_nil
  end

  it "does not remind someone who booked inside the window" do
    booking = session_in(5).book!(member)

    described_class.perform_now

    expect(booking.reload.reminder_sent_at).to be_nil
  end

  it "skips cancelled bookings and cancelled sessions" do
    cancelled_booking = booked(session_in(10))
    cancelled_booking.cancel!
    called_off = session_in(12)
    other = booked(called_off)
    called_off.cancel!

    described_class.perform_now

    expect(cancelled_booking.reload.reminder_sent_at).to be_nil
    expect(other.reload.reminder_sent_at).to be_nil
  end

  it "sends the SMS too when the gym pays for it, and survives a gateway failure" do
    company.update!(settings: { booking: { reminder_sms: true } })
    booking = booked(session_in(10))
    allow(Sms::TunisieSmsClient).to receive(:send_message)
      .and_raise(Sms::TunisieSmsClient::RequestError, "gateway down")

    expect { described_class.perform_now }.not_to raise_error
    expect(Sms::TunisieSmsClient).to have_received(:send_message)
    expect(booking.reload.reminder_sent_at).to be_present
  end

  it "sends no SMS by default" do
    booked(session_in(10))
    allow(Sms::TunisieSmsClient).to receive(:send_message)

    described_class.perform_now

    expect(Sms::TunisieSmsClient).not_to have_received(:send_message)
  end
end
