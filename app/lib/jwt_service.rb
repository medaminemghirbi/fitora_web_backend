class JwtService
  ALGORITHM = "HS256".freeze
  EXPIRATION = 7.days
  # A superadmin working inside someone else's account should have to mean it
  # again after an hour, not carry that access around for a week.
  IMPERSONATION_EXPIRATION = 1.hour

  class DecodeError < StandardError; end

  # The usual way in: a token for this account, at its current
  # token_version, so bumping the version (TokenVersioned) ends it.
  def self.for_user(user, impersonator: nil)
    encode(user.id, impersonator_id: impersonator&.id, token_version: user.token_version,
                    expires_in: impersonator ? IMPERSONATION_EXPIRATION : EXPIRATION)
  end

  def self.for_client(client)
    encode(client_id: client.id, token_version: client.token_version)
  end

  # impersonator_id is only set for a superadmin-initiated impersonation session
  # (see Api::V1::Superadmin::CompaniesController#impersonate) — it lets
  # authenticate_request! surface who is really behind the wheel without
  # changing what current_user resolves to (still the impersonated admin, so
  # every existing admin-only guard/capability check keeps working as-is).
  #
  # client_id is the other kind of token — issued for a Client's own mobile
  # login (see Api::V1::AuthController#login), mutually exclusive with
  # user_id.
  #
  # tv is the account's token_version at issue. A token without one (issued
  # before versions were checked) reads as version 0, so it keeps working
  # until the account's version first moves.
  def self.encode(user_id = nil, client_id: nil, impersonator_id: nil, token_version: 0, expires_in: EXPIRATION)
    payload = { exp: expires_in.from_now.to_i, iat: Time.current.to_i, tv: token_version }
    payload[:user_id] = user_id if user_id
    payload[:client_id] = client_id if client_id
    payload[:impersonator_id] = impersonator_id if impersonator_id
    JWT.encode(payload, secret, ALGORITHM)
  end

  CABLE_TICKET_EXPIRATION = 30.seconds

  # A pass for one WebSocket connection (Api::V1::AuthController#cable_ticket).
  # Short-lived because it travels in a URL, single-use through its jti
  # (ApplicationCable::Connection), and marked so it cannot stand in for a
  # login token, nor a login token for it.
  def self.cable_ticket_for(account)
    payload = {
      purpose: "cable", jti: SecureRandom.uuid, tv: account.token_version,
      exp: CABLE_TICKET_EXPIRATION.from_now.to_i
    }
    payload[account.is_a?(Client) ? :client_id : :user_id] = account.id
    JWT.encode(payload, secret, ALGORITHM)
  end

  def self.decode_cable_ticket(ticket)
    payload = JWT.decode(ticket, secret, true, algorithm: ALGORITHM).first
    raise DecodeError unless payload["purpose"] == "cable"

    {
      user_id: payload["user_id"], client_id: payload["client_id"],
      token_version: payload["tv"].to_i, jti: payload["jti"]
    }
  rescue JWT::DecodeError, JWT::ExpiredSignature
    raise DecodeError
  end

  def self.decode(token)
    payload = JWT.decode(token, secret, true, algorithm: ALGORITHM).first
    # A cable ticket is not a login.
    raise DecodeError if payload["purpose"].present?

    {
      user_id: payload["user_id"], client_id: payload["client_id"],
      impersonator_id: payload["impersonator_id"], token_version: payload["tv"].to_i
    }
  rescue JWT::DecodeError, JWT::ExpiredSignature
    raise DecodeError
  end

  def self.secret
    Rails.application.secret_key_base
  end
end
