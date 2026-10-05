class ApplicationMailer < ActionMailer::Base
  # Was the Rails placeholder ("from@example.com") — never actually
  # configured, because AccountMailer is the first mailer in this app that
  # sends anything for real.
  default from: ENV.fetch("MAIL_FROM", "Fitora <no-reply@fitora.io>")
  layout "mailer"
end
