module Api
  module V1
    class AuthController < ApplicationController
      before_action :authenticate_request!, only: [ :me, :logout, :permissions, :change_password, :cable_ticket ]

      # POST /api/v1/auth/register — a gym opening its own account.
      #
      # Creates the admin's login and nothing else. The token it returns
      # opens exactly one screen — "check your inbox" — until the emailed
      # link is clicked (BaseController#require_confirmed_email!). Only then
      # is the gym named (Api::V1::CompaniesController#create), which is
      # also where the 14 days start. Splitting it that way keeps this form
      # to three fields for someone who has not seen the product yet.
      #
      # The 14 days are all this grants. Carrying on past them still means
      # asking Gymly to activate the account (SubscriptionController
      # #request_upgrade) — signing up moves that conversation after the
      # trial, it does not remove it.
      def register
        user = User.new(register_params.merge(role: :admin))

        if user.save
          raw = user.generate_email_verification_token!
          AccountMailer.email_verification(user, raw).deliver_later
          render json: {
            token: JwtService.for_user(user),
            account_type: "user",
            user: UserSerializer.new(user).as_json
          }, status: :created
        else
          render_errors(user)
        end
      end

      # POST /api/v1/auth/login — one door for both kinds of account.
      #
      # A platform account first (admin, staff, Gymly superadmin), then a member
      # whose gym enabled their access. account_type says which came back, so
      # the caller sends them to the right home without asking who they are
      # first. A gym signs itself up (#register); a member never does — their
      # access is switched on from their own file by the gym.
      def login
        email = params[:email].to_s.downcase.strip

        user = User.active.find_by(email: email)
        if user&.authenticate(params[:password])
          return render json: { token: JwtService.for_user(user), account_type: "user", user: UserSerializer.new(user).as_json }
        end

        client = Client.active.where.not(password_digest: nil).find_by(email: email)
        if client&.authenticate(params[:password])
          # The member app is a Pro feature. Said only after the password
          # checked out, so it tells nobody but the member which gyms exist.
          unless client.companies.includes(admin: { subscription: :invoices }).any?(&:member_app?)
            return render json: {
              error: "member_app_not_included",
              message: "Your gym's plan does not include the member app."
            }, status: :forbidden
          end

          return render json: { token: JwtService.for_client(client), account_type: "client", client: ClientSerializer.new(client).as_json }
        end

        render json: { error: "Invalid email or password" }, status: :unauthorized
      end

      # POST /api/v1/auth/logout — { all_devices: true } to sign out everywhere.
      #
      # A plain logout is the client discarding its token. Every device at
      # once moves the account's token_version on, which ends every token
      # issued before it (see TokenVersioned).
      def logout
        current_account.revoke_all_tokens! if ActiveModel::Type::Boolean.new.cast(params[:all_devices])
        head :no_content
      end

      # PATCH /api/v1/auth/password — { current_password:, password: }
      #
      # For someone already signed in. The new password ends every other
      # session (TokenVersioned); this one gets a fresh token back so the
      # person changing it is not signed out in the same breath.
      def change_password
        # Helping inside someone's account never extends to their password.
        return render_forbidden if current_impersonator

        account = current_account
        unless account.authenticate(params[:current_password].to_s)
          return render json: { error: "current_password_invalid", errors: [ "Current password is incorrect" ] },
                        status: :unprocessable_content
        end

        if params[:password].blank?
          return render json: { error: "Password can't be blank", errors: [ "Password can't be blank" ] },
                        status: :unprocessable_content
        end

        if account.update(password: params[:password])
          token = account.is_a?(Client) ? JwtService.for_client(account) : JwtService.for_user(account)
          render json: { token: token }
        else
          render_errors(account)
        end
      end

      # POST /api/v1/cable_ticket
      #
      # Browsers cannot set headers on a WebSocket handshake, so whatever
      # authenticates /cable rides in its URL — where proxy and access logs
      # keep it. That used to be the 7-day login token. This is a pass that
      # expires in 30 seconds and opens one connection.
      def cable_ticket
        render json: { ticket: JwtService.cable_ticket_for(current_account) }
      end

      # GET /api/v1/auth/me
      def me
        if current_client
          render json: { account_type: "client", client: ClientSerializer.new(current_client).as_json }
        else
          render json: { account_type: "user", user: UserSerializer.new(current_user).as_json }
        end
      end

      # GET /api/v1/me/permissions — the resolved capability list for the
      # signed-in staff login, plus the role it came from. The frontend
      # renders navigation and guards page access from this rather than a
      # hard-coded map. Admins get every permission; a platform superadmin gets
      # none (the /superadmin surface isn't capability-gated).
      def permissions
        resolved = Permissions::Resolve.call(user: current_user)
        render json: { role: resolved.role, permissions: resolved.permissions }
      end

      private

      def current_account
        current_client || current_user
      end

      # `role` is never taken from the form: everyone who signs up here is an
      # admin, and a staff login is created by their gym.
      def register_params
        params.require(:user).permit(:first_name, :last_name, :email, :password, :phone, :locale)
      end
    end
  end
end
