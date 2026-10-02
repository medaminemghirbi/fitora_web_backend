class ApplicationController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from ActiveRecord::RecordInvalid, with: :render_unprocessable
  rescue_from ActionController::ParameterMissing, with: :render_bad_request

  private

  def authenticate_request!
    token = request.headers["Authorization"]&.split(" ")&.last
    render_unauthorized and return if token.blank?

    claims = JwtService.decode(token)

    if claims[:client_id]
      @current_client = Client.active.find_by(id: claims[:client_id])
      # A token from before a password change or "sign out everywhere".
      @current_client = nil unless @current_client&.token_current?(claims[:token_version])
      render_unauthorized if @current_client.nil?
    else
      @current_user = User.active.find_by(id: claims[:user_id])
      @current_user = nil unless @current_user&.token_current?(claims[:token_version])
      if claims[:impersonator_id]
        @current_impersonator = User.active.superadmin.find_by(id: claims[:impersonator_id])
        # So every audit log written during this request says who was really
        # at the keyboard — current_user is the impersonated admin throughout.
        Current.impersonator = @current_impersonator
        # An impersonation whose superadmin is gone, or no longer a superadmin, is over.
        @current_user = nil if @current_impersonator.nil?
      end
      render_unauthorized if @current_user.nil?
    end

    tag_sentry_context!
  rescue JwtService::DecodeError
    render_unauthorized
  end

  # Attaches whoever a request is for to any error Sentry captures during
  # it — the difference between "something broke" and "something broke
  # for this one company," which matters once there's more than a
  # handful of tenants. Sentry.set_user/set_tags are safe no-ops on their
  # own when Sentry was never initialized (no SENTRY_DSN, see
  # config/initializers/sentry.rb). Reads current_user/current_client
  # directly rather than the current_company helper
  # (Api::V1::BaseController-only) so this stays safe to call from every
  # controller that authenticates, not just that one subclass.
  def tag_sentry_context!
    if current_client
      Sentry.set_user(id: current_client.id, email: current_client.email)
      Sentry.set_tags(account_type: "client")
    elsif current_user
      Sentry.set_user(id: current_user.id, email: current_user.email)
      Sentry.set_tags(
        account_type: "user", role: current_user.role,
        company_id: current_user.current_company&.id
      )
    end
  end

  def current_user
    @current_user
  end

  # A member signed in on their own app — mutually exclusive with
  # current_user, never both (see JwtService.encode). Every staff-facing
  # controller keeps assuming current_user, so the member endpoints live in
  # their own Api::V1::Me namespace and gate on require_client!.
  def current_client
    @current_client
  end

  # The superadmin who is impersonating current_user, if this is an impersonation
  # session — nil for a normal login. See JwtService.encode.
  def current_impersonator
    @current_impersonator
  end

  def render_unauthorized
    render json: { error: "Unauthorized" }, status: :unauthorized
  end

  def render_forbidden(message = "You are not allowed to perform this action")
    render json: { error: message }, status: :forbidden
  end

  def render_not_found
    render json: { error: "Resource not found" }, status: :not_found
  end

  def render_bad_request(exception)
    render json: { error: exception.message }, status: :bad_request
  end

  # The one shape a refused write answers with: the first message to show,
  # and all of them.
  def render_errors(record_or_messages, status: :unprocessable_content)
    messages = record_or_messages.respond_to?(:errors) ? record_or_messages.errors.full_messages : Array(record_or_messages)
    render json: { error: messages.first || "Validation failed", errors: messages }, status: status
  end

  def render_unprocessable(exception = nil)
    render_errors(exception&.record || [ exception&.message ].compact)
  end
end
