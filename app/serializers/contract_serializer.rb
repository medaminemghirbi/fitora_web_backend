class ContractSerializer
  def initialize(contract)
    @contract = contract
  end

  def as_json(*)
    return nil if contract.nil?

    {
      id: contract.id,
      # FAC-2026-0001 — on the receipt and the signed contract.
      invoice_ref: contract.invoice_ref,
      status: contract.status,
      # On hold (Contract#pause!): nothing books against it, and expires_at
      # moves on resume by however long it was held.
      paused: contract.paused?,
      paused_at: contract.paused_at,
      starts_at: contract.starts_at,
      expires_at: contract.expires_at,
      remaining_bookings: contract.remaining_bookings,
      auto_renew: contract.auto_renew,
      discount: contract.discount,
      base_price: contract.base_price,
      final_price: contract.final_price,
      payment_status: contract.payment_status,
      # No part payments — a contract is owed in full or not at all.
      amount_due: contract.amount_due,
      plan: ContractTypeSerializer.new(contract.contract_type).as_json,
      # null for an all-access contract, which covers every activity its plan
      # covers rather than naming one. Read `all_access` to tell that apart
      # from missing data, and `activity_label` for something to show.
      activity: contract.activity && {
        id: contract.activity.id, name: contract.activity.name, emoji: contract.activity.emoji
      },
      # Set instead of `activity` when the contract sells a pack.
      pack: contract.pack && {
        id: contract.pack.id, name: contract.pack.name, activity_names: contract.pack.activity_names
      },
      # The term this one renews, and the term sold to follow it — each a
      # contract of its own. A renewal made before this term runs out never
      # replaces it: both are kept, so both are shown.
      renewed_from_id: contract.renewed_from_id,
      renewal: renewal_summary(contract.renewal),
      # Whether "Renouveler" applies: the last term of its chain, within
      # Contract::RENEWAL_WINDOW of its end (or ended, or out of sessions).
      renewable: contract.renewable?,
      all_access: contract.all_access?,
      activity_label: contract.activity_label,
      client: { id: contract.client.id, full_name: contract.client.full_name, phone: contract.client.phone }
    }
  end

  private

  attr_reader :contract

  def renewal_summary(renewal)
    renewal && {
      id: renewal.id,
      starts_at: renewal.starts_at,
      expires_at: renewal.expires_at,
      final_price: renewal.final_price,
      payment_status: renewal.payment_status,
      plan_name: renewal.contract_type.name
    }
  end
end
