class ContractTypeSerializer
  def initialize(plan)
    @plan = plan
  end

  def as_json(*)
    {
      id: plan.id,
      company_id: plan.company_id,
      name: plan.name,
      description: plan.description,
      currency: plan.currency,
      billing_period: plan.billing_period,
      duration_days: plan.duration_days,
      validity_days: plan.validity_days,
      session_count: plan.session_count,
      unlimited_bookings: plan.unlimited_bookings,
      booking_limit: plan.booking_limit,
      priority_booking: plan.priority_booking,
      color: plan.color,
      active: plan.active,
      activity_ids: plan.contract_type_activities.map(&:activity_id),
      # The pricing grid: what each activity costs under this plan. Read from
      # the association as loaded, so a list that preloaded it costs nothing.
      activity_prices: plan.contract_type_activities.map { |row|
        { activity_id: row.activity_id, activity_name: row.activity.name, activity_emoji: row.activity.emoji, price: row.price }
      },
      # The same grid for packs: one row per pack this plan is sold for.
      pack_prices: plan.contract_type_packs.map { |row|
        { pack_id: row.pack_id, pack_name: row.pack.name, activity_names: row.pack.activity_names, price: row.price }
      }
    }
  end

  private

  attr_reader :plan
end
