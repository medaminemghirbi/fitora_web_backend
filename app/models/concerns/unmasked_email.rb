# Refuses an e-mail address that is a masked one (EmailMask): a form filled
# from a masked response and saved unchanged must bounce, never overwrite
# the real address with "ex****le@gmail.com".
module UnmaskedEmail
  extend ActiveSupport::Concern

  included do
    validate :email_not_masked
  end

  private

  def email_not_masked
    return unless will_save_change_to_email? && EmailMask.masked?(email)

    errors.add(:email, :invalid, message: "is a masked address — type the full address")
  end
end
