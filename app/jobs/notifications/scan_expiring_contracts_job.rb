module Notifications
  # Daily: client contracts whose active period is within its warning window.
  class ScanExpiringContractsJob < ApplicationJob
    queue_as :default

    def perform
      ContractPeriod
        .expiring_soon(within: ContractPeriod::NOTIFY_WITHIN)
        .includes(contract: [ :company, :client, :contract_type ])
        .find_each { |period| notify(period) }
    end

    def notify(period)
      contract = period.contract
      tell_member(period, contract) if contract
      admin = contract&.company&.admin
      return if admin.nil?

      Notification.push(
        recipient: admin,
        kind: "contract_expiring",
        subject: period,
        dedup_key: "contract_exp:#{period.id}:#{period.expires_at.to_date}",
        url: "/admin/clients/#{contract.client_id}",
        data: {
          client_name: contract.client&.full_name,
          contract_type: contract.contract_type&.name,
          expires_at: period.expires_at&.iso8601
        }
      )
    end

    # The member hears it too, on their own app: renewing is their decision.
    def tell_member(period, contract)
      Notification.push(
        recipient: contract.client, company: contract.company, kind: "subscription_expiring", subject: period,
        dedup_key: "subscription_expiring:#{period.id}:#{period.expires_at.to_date}", url: "/member/profile",
        data: {
          plan_name: contract.contract_type&.name, expires_at: period.expires_at&.iso8601,
          gym_name: contract.company&.name
        }
      )
    end
  end
end
