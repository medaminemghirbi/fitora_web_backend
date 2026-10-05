require "net/http"

module Sms
  # Thin wrapper around TunisieSMS's HTTP API (client-supplied Api.aspx GET
  # endpoint — the same one their Java sample hits). Credentials come from
  # ENV (TUNISIESMS_API_KEY / TUNISIESMS_SENDER), never hardcoded — set them
  # in your .env / deployment environment; there's no working default key.
  class TunisieSmsClient
    class ConfigurationError < StandardError; end
    class RequestError < StandardError; end

    BASE_URL = "https://www.tunisiesms.tn/client/Api/Api.aspx".freeze

    def self.send_message(mobile:, text:)
      new.send_message(mobile: mobile, text: text)
    end

    def initialize(api_key: ENV["TUNISIESMS_API_KEY"], sender: ENV.fetch("TUNISIESMS_SENDER", "Fitora"))
      @api_key = api_key
      @sender = sender
    end

    def send_message(mobile:, text:)
      raise ConfigurationError, "TUNISIESMS_API_KEY is not set" if api_key.blank?

      now = Time.current
      uri = URI(BASE_URL)
      uri.query = URI.encode_www_form(
        fct: "sms",
        key: api_key,
        mobile: mobile,
        sms: text,
        sender: sender,
        date: now.strftime("%d/%m/%Y"),
        heure: now.strftime("%H:%M:%S")
      )

      response = Net::HTTP.get_response(uri)
      raise RequestError, "TunisieSMS request failed (#{response.code})" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end

    private

    attr_reader :api_key, :sender
  end
end
