module Companies
  # Sets which of an admin's moderators work at one of their salles.
  #
  # A login works at a salle by holding a staff record there, so posting a
  # moderator creates one — on that salle's role with the same key as their
  # first post, since roles belong to each salle; the built-in moderator
  # role when the salle has no such role. Taking them off deletes that
  # salle's record and nothing else: their other salles, and the login, stay.
  #
  # "Moderators" here is every staff login but the coaches. A coach teaches
  # one salle's timetable from its own Coach record there, so it is not
  # something to post somewhere else.
  class PostModerators
    Result = ServiceResult.define(:company)

    def self.call(company:, user_ids:, by:) = new(company: company, user_ids: user_ids, by: by).call

    # Everyone the admin can post: the non-coach staff logins working at any
    # of their salles.
    def self.team_for(admin)
      User.staff.where(id: admin.salle_staff_members.where(coach_id: nil).select(:user_id))
    end

    def initialize(company:, user_ids:, by:)
      @company = company
      @user_ids = Array(user_ids).map(&:to_s).compact_blank.uniq
      @by = by
    end

    def call
      wanted = self.class.team_for(company.admin).where(id: user_ids).to_a
      return Result.failure("Unknown moderator.") if wanted.size != user_ids.size

      posted = company.staff_members.where(coach_id: nil).includes(:user).to_a
      leaving = posted.reject { |record| user_ids.include?(record.user_id) }
      joining = wanted.reject { |user| posted.any? { |record| record.user_id == user.id } }

      stranded = leaving.find { |record| record.user.staff_members.count <= 1 }
      if stranded
        return Result.failure("#{stranded.full_name} works at no other salle. Deactivate them from the team page instead.")
      end

      ActiveRecord::Base.transaction do
        leaving.each { |record| withdraw(record) }
        joining.each { |user| post(user) }
      end

      Result.ok(company: company)
    rescue ActiveRecord::RecordInvalid => e
      Result.failure(e.record.errors.full_messages.first)
    end

    private

    attr_reader :company, :user_ids, :by

    def post(user)
      record = company.staff_members.create!(user: user, assigned_role: role_for(user))
      AuditLogs::Record.call(
        company: company, user: by, action: "staff.posted",
        auditable: record, metadata: { staff_email: user.email, role: record.role_key }
      )
    end

    def withdraw(record)
      user = record.user
      # Not left working in a salle they are no longer part of: their next
      # request resolves to one of the salles they still have.
      user.update!(active_company: nil) if user.active_company_id == company.id
      record.destroy!
      AuditLogs::Record.call(
        company: company, user: by, action: "staff.withdrawn",
        auditable: company, metadata: { staff_email: user.email }
      )
    end

    def role_for(user)
      key = user.staff_members.where(coach_id: nil).includes(:assigned_role).min_by(&:created_at)&.role_key
      company.roles.find_by(key: key) || company.roles.find_by!(key: "moderator")
    end
  end
end
