class PackSerializer
  def initialize(pack)
    @pack = pack
  end

  def as_json(*)
    {
      id: pack.id,
      name: pack.name,
      description: pack.description,
      active: pack.active,
      currency: pack.company.currency,
      activity_ids: pack.activities.map(&:id),
      activities: pack.activities.sort_by(&:name).map { |a| { id: a.id, name: a.name, emoji: a.emoji } },
      # What the pack is sold at, per formule — read-only here; the grid is
      # edited on the formule, as it is for an activity.
      prices: pack.contract_type_packs.map { |row|
        {
          contract_type_id: row.contract_type_id,
          contract_type_name: row.contract_type.name,
          billing_period: row.contract_type.billing_period,
          validity_days: row.contract_type.validity_days,
          price: row.price
        }
      }
    }
  end

  private

  attr_reader :pack
end
