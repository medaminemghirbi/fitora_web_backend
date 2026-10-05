class ActivitySerializer
  def initialize(activity)
    @activity = activity
  end

  def as_json(*)
    {
      id: activity.id,
      name: activity.name,
      emoji: activity.emoji,
      # The catalogue entry it was copied from; null for one the gym named itself.
      activity_template_id: activity.activity_template_id,
      description: activity.description,
      session_format: activity.session_format,
      duration: activity.duration,
      capacity: activity.capacity,
      active: activity.active,
      currency: activity.company.currency,
      # What this activity is sold at, per plan — read-only here; the grid
      # is edited on the plan itself (Settings > Types de contrat).
      prices: activity.contract_type_activities.includes(:contract_type).map { |row|
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

  attr_reader :activity
end
