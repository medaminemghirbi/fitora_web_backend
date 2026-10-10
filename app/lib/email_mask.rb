# How someone else's e-mail address leaves the API: "ex****le@gmail.com".
#
# The address is stored as it is (it is how people sign in and how mail
# reaches them); what is masked is every response that shows it to someone
# other than its owner. The owner's own session, an admin's edit form
# (reveal: true on a single record) and the admin's CSV export keep it whole.
#
# The domain stays readable: it is what tells "gmail" from a work address,
# and it identifies nobody.
module EmailMask
  STARS = "****".freeze

  module_function

  def call(email)
    return email if email.blank?

    local, domain = email.to_s.split("@", 2)
    return STARS if domain.nil?

    shown = local.length <= 4 ? "#{local[0]}#{STARS}" : "#{local[0, 2]}#{STARS}#{local[-2, 2]}"
    "#{shown}@#{domain}"
  end

  # A value that came back from a masked field — never a real address.
  def masked?(value)
    value.to_s.include?(STARS)
  end
end
