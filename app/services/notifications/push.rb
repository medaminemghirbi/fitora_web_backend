module Notifications
  # Creates one notification per (company, dedup_key), idempotently. Creating
  # it fires Notification#broadcast (real-time push + badge count). Safe to
  # call from a daily scan and from a synchronous after_commit hook.
  class Push
    # `company` is required for a member: they belong to several gyms, and
    # the notification comes from one of them. For a User it is derived.
    def self.call(recipient:, kind:, data:, url:, dedup_key:, subject: nil, company: nil)
      return nil if recipient.nil?

      if recipient.is_a?(Client)
        # Nobody to tell: a member without their app never reads these.
        return nil if company.nil? || !recipient.login_enabled?
      else
        # Every company-scoped notification still requires one (a nil company
        # here would silently be a bug in the caller); a platform-level event
        # aimed at a Gymly superadmin has none by design — see Notification#company.
        company = recipient.current_company
        return nil if company.nil? && !recipient.superadmin?
      end

      recipient.notifications.create!(
        company: company,
        kind: kind,
        data: data,
        url: url,
        dedup_key: dedup_key,
        subject: subject
      )
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # Unique index on [company_id, dedup_key] — already notified. Not an error.
      raise unless e.is_a?(ActiveRecord::RecordNotUnique) || e.record&.errors&.of_kind?(:dedup_key, :taken)

      recipient.notifications.find_by(dedup_key: dedup_key)
    end
  end
end
