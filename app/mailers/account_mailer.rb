# The first real transactional mailer in the app (ApplicationMailer existed
# but nothing subclassed it yet) — password reset + email verification,
# shared by User (admin/staff — never superadmin, see
# Api::V1::PasswordResetsController) and Client.
class AccountMailer < ApplicationMailer
  # The Angular SPA's own origin — see config.x.frontend_url, the one place
  # it is decided, which production's host list reads too.
  FRONTEND_URL = Rails.configuration.x.frontend_url

  def password_reset(record, raw_token)
    @record = record
    @first_name = record.respond_to?(:first_name) ? record.first_name : nil
    @reset_url = "#{FRONTEND_URL}/auth/reset-password?token=#{raw_token}"
    @expires_in_minutes = PasswordResettable::TOKEN_EXPIRY.to_i / 60

    mail(to: record.email, subject: "Réinitialisez votre mot de passe Fitora")
  end

  def email_verification(record, raw_token)
    @record = record
    @first_name = record.respond_to?(:first_name) ? record.first_name : nil
    @verify_url = "#{FRONTEND_URL}/verify-email?token=#{raw_token}"
    @expires_in_days = EmailVerifiable::TOKEN_EXPIRY.to_i / 1.day
    # For an admin the link is what opens the account, and the mail says so.
    @opens_account = record.is_a?(User) && record.admin?

    mail(to: record.email, subject: "Confirmez votre adresse e-mail Fitora")
  end

  # A gym switching on a member's own app. The member chooses their password
  # from the link; the gym never sees it.
  def member_invitation(client, company, raw_token)
    @first_name = client.first_name
    @gym_name = company.name
    @invite_url = "#{FRONTEND_URL}/auth/accept-invitation?token=#{raw_token}"
    @expires_in_days = Invitable::INVITATION_EXPIRY.to_i / 1.day

    mail(to: client.email, subject: "#{company.name} vous invite sur Fitora")
  end
end
