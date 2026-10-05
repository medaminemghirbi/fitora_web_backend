module Api
  module V1
    # Forgot-password — unauthenticated by design, same as PairingController.
    # Never for a platform superadmin (role: :superadmin) — Fitora operators aren't
    # self-service here, same line as everywhere else that special-cases them.
    class PasswordResetsController < ApplicationController
      # POST /api/v1/password_resets — { email: }. Always the same response
      # whether or not the email matches an account, so this can't be used
      # to enumerate registered emails.
      def create
        record = find_recoverable(params[:email])

        if record
          raw = record.generate_password_reset_token!
          AccountMailer.password_reset(record, raw).deliver_later
        end

        head :no_content
      end

      # PATCH /api/v1/password_resets/:token — { password: }
      def update
        record = User.active.where.not(role: :superadmin).find_by_reset_password_token(params[:token]) ||
                 Client.active.find_by_reset_password_token(params[:token])

        return render(json: { error: "invalid_or_expired_token" }, status: :unprocessable_content) if record.nil?

        if record.update(password: params[:password])
          record.clear_password_reset_token!
          head :no_content
        else
          render_errors(record)
        end
      end

      private

      def find_recoverable(email)
        normalized = email.to_s.downcase.strip
        return nil if normalized.blank?

        User.active.where.not(role: :superadmin).find_by(email: normalized) ||
          Client.active.where.not(password_digest: nil).find_by(email: normalized)
      end
    end
  end
end
