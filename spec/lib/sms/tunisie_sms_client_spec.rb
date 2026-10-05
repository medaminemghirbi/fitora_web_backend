require "rails_helper"

RSpec.describe Sms::TunisieSmsClient do
  describe "#send_message" do
    it "sends the SMS and returns the response body on success" do
      client = described_class.new(api_key: "test-key", sender: "Fitora")
      response = instance_double(Net::HTTPOK, is_a?: true, body: "OK")
      captured_uri = nil
      allow(Net::HTTP).to receive(:get_response) do |uri|
        captured_uri = uri
        response
      end

      result = client.send_message(mobile: "+21620000000", text: "Hello")

      expect(result).to eq("OK")
      expect(captured_uri.to_s).to start_with(described_class::BASE_URL)
      expect(captured_uri.query).to include("key=test-key")
      expect(captured_uri.query).to include("sender=Fitora")
      expect(captured_uri.query).to include("sms=Hello")
    end

    it "raises ConfigurationError when no api key is configured" do
      client = described_class.new(api_key: nil, sender: "Fitora")

      expect do
        client.send_message(mobile: "+21620000000", text: "Hello")
      end.to raise_error(described_class::ConfigurationError, "TUNISIESMS_API_KEY is not set")
    end

    it "raises RequestError when the HTTP call does not succeed" do
      client = described_class.new(api_key: "test-key", sender: "Fitora")
      response = instance_double(Net::HTTPBadRequest, is_a?: false, code: "400")
      allow(Net::HTTP).to receive(:get_response).and_return(response)

      expect do
        client.send_message(mobile: "+21620000000", text: "Hello")
      end.to raise_error(described_class::RequestError, "TunisieSMS request failed (400)")
    end
  end

  describe ".send_message" do
    it "delegates to a new instance built from the default credentials" do
      instance = instance_double(described_class)
      allow(described_class).to receive(:new).and_return(instance)
      allow(instance).to receive(:send_message).with(mobile: "+21620000000", text: "Hi").and_return("OK")

      result = described_class.send_message(mobile: "+21620000000", text: "Hi")

      expect(result).to eq("OK")
      expect(instance).to have_received(:send_message).with(mobile: "+21620000000", text: "Hi")
    end
  end
end
