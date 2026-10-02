module Notifications
  # Daily: wish the admin a happy birthday for each team member (coaches, and
  # non-coach staff) whose birthdate falls today. One notification per person
  # per year.
  class ScanEmployeeBirthdaysJob < ApplicationJob
    queue_as :default

    def perform
      Coach.active.where.not(birthdate: nil).includes(:company).find_each do |coach|
        next unless birthday_today?(coach.birthdate, coach.company)

        notify(coach.company&.admin, subject: coach, name: coach.full_name, url: "/admin/team")
      end

      StaffMember.active.where(coach_id: nil).where.not(birthdate: nil).includes(:company, :user).find_each do |staff|
        next unless birthday_today?(staff.birthdate, staff.company)

        notify(staff.company&.admin, subject: staff, name: staff.full_name, url: "/admin/team/#{staff.id}")
      end
    end

    # Today where the gym is, not in UTC.
    def birthday_today?(birthdate, company)
      today = company ? company.time_zone.today : Date.current
      birthdate.strftime("%m-%d") == today.strftime("%m-%d")
    end

    def notify(admin, subject:, name:, url:)
      return if admin.nil? || name.blank?

      Notification.push(
        recipient: admin,
        kind: "employee_birthday",
        subject: subject,
        dedup_key: "birthday:#{subject.class.name}:#{subject.id}:#{Date.current.year}",
        url: url,
        data: { name: name }
      )
    end
  end
end
