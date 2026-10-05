module Notifications
  # Fired from Contract#after_commit when a contract's expiry lands in the
  # warning window.
  class ContractExpiryChangedJob < ApplicationJob
    queue_as :default
    discard_on ActiveJob::DeserializationError

    def perform(contract_id)
      contract = Contract.includes(:company, :client, :contract_type).find_by(id: contract_id)
      return if contract.nil? || !contract.expiring_soon? || contract.renewal

      ScanExpiringContractsJob.new.notify(contract)
    end
  end
end
