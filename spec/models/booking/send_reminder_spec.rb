require "rails_helper"

RSpec.describe Booking, "#send_reminder!" do
  let(:company) { create(:company, name: "Fitora Test Gym") }
  let(:activity) { create(:activity, company: company, name: "Yoga") }
  let(:session) { create(:session, activity: activity, company: company, starts_at: Time.zone.local(2026, 9, 20, 18, 0)) }

  it "sends an SMS to the client's normalized mobile number" do
    client = create(:client, company: company, first_name: "Ines", phone: "+216 20 111 222")
    booking = create(:booking, client: client, session: session)

    expect(Sms::TunisieSmsClient).to receive(:send_message).with(
      mobile: "21620111222",
      text: a_string_matching(/Ines.*Yoga.*20\/09\/2026.*18:00.*Fitora Test Gym/)
    )

    booking.send_reminder!
  end

  it "fills in the 216 country code for a local 8-digit number" do
    client = create(:client, company: company, phone: "20 111 222")
    booking = create(:booking, client: client, session: session)

    expect(Sms::TunisieSmsClient).to receive(:send_message).with(mobile: "21620111222", text: anything)

    booking.send_reminder!
  end

  it "refuses when the client has no usable phone number" do
    client = create(:client, company: company, phone: "n/a")
    booking = create(:booking, client: client, session: session)

    expect(Sms::TunisieSmsClient).not_to receive(:send_message)

    expect { booking.send_reminder! }.to raise_error(ApplicationRecord::Refused, "Client has no usable phone number")
  end

  it "refuses with the gateway's reason rather than failing outright" do
    client = create(:client, company: company, phone: "+216 20 111 222")
    booking = create(:booking, client: client, session: session)

    allow(Sms::TunisieSmsClient).to receive(:send_message).and_raise(Sms::TunisieSmsClient::ConfigurationError, "TUNISIESMS_API_KEY is not set")

    expect { booking.send_reminder! }.to raise_error(ApplicationRecord::Refused, "TUNISIESMS_API_KEY is not set")
  end
end
