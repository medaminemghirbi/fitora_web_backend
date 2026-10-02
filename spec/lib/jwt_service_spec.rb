require "rails_helper"

RSpec.describe JwtService do
  describe ".encode / .decode" do
    it "round-trips a user id" do
      token = described_class.encode(42)

      payload = described_class.decode(token)

      expect(payload[:user_id]).to eq(42)
      expect(payload[:client_id]).to be_nil
      expect(payload[:impersonator_id]).to be_nil
    end

    it "round-trips a client_id token" do
      token = described_class.encode(client_id: 7)

      payload = described_class.decode(token)

      expect(payload[:client_id]).to eq(7)
      expect(payload[:user_id]).to be_nil
    end

    it "round-trips an impersonator_id alongside the user_id" do
      token = described_class.encode(1, impersonator_id: 99)

      payload = described_class.decode(token)

      expect(payload[:user_id]).to eq(1)
      expect(payload[:impersonator_id]).to eq(99)
    end

    it "keeps a token valid within its 7 day expiration window" do
      token = nil
      travel_to Time.zone.local(2026, 1, 1, 12, 0, 0) do
        token = described_class.encode(1)
      end

      travel_to Time.zone.local(2026, 1, 8, 11, 0, 0) do # 6 days, 23 hours later
        expect { described_class.decode(token) }.not_to raise_error
      end
    end

    it "raises DecodeError once the token has expired" do
      token = nil
      travel_to Time.zone.local(2026, 1, 1, 12, 0, 0) do
        token = described_class.encode(1)
      end

      travel_to Time.zone.local(2026, 1, 8, 13, 0, 0) do # 7 days, 1 hour later
        expect { described_class.decode(token) }.to raise_error(JwtService::DecodeError)
      end
    end

    it "raises DecodeError for a garbage token" do
      expect { described_class.decode("not-a-real-token") }.to raise_error(JwtService::DecodeError)
    end

    it "raises DecodeError for a tampered token" do
      token = described_class.encode(1)
      last_char = token[-1]
      tampered = "#{token.chop}#{last_char == 'a' ? 'b' : 'a'}"

      expect { described_class.decode(tampered) }.to raise_error(JwtService::DecodeError)
    end
  end
end
