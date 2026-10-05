module Notifications
  # Daily: client contracts within their warning window. One already renewed
  # is not running out — the member's cover carries on into the next term.
  class ScanExpiringContractsJob < ApplicationJob
    queue_as :default

    def perform
      Contract
        .expiring_soon(within: Contract::NOTIFY_WITHIN)
        .not_renewed
        .includes(:company, :client, :contract_type)
        .find_each { |contract| notify(contract) }
    end

    def notify(contract)
      tell_member(contract)
      admin = contract.company&.admin
      return if admin.nil?

      Notification.push(
        recipient: admin,
        kind: "contract_expiring",
        subject: contract,
        dedup_key: "contract_exp:#{contract.id}:#{contract.expires_at.to_date}",
        url: "/admin/clients/#{contract.client_id}",
        data: {
          client_name: contract.client&.full_name,
          contract_type: contract.contract_type&.name,
          expires_at: contract.expires_at&.iso8601
        }
      )
    end

    # The member hears it too, on their own app: renewing is their decision.
    def tell_member(contract)
      Notification.push(
        recipient: contract.client, company: contract.company, kind: "subscription_expiring", subject: contract,
        dedup_key: "subscription_expiring:#{contract.id}:#{contract.expires_at.to_date}", url: "/member/profile",
        data: {
          plan_name: contract.contract_type&.name, expires_at: contract.expires_at&.iso8601,
          gym_name: contract.company&.name
        }
      )
    end
  end
end
