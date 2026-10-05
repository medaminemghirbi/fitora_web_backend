class BookingSerializer
  def initialize(booking)
    @booking = booking
  end

  def as_json(*)
    {
      id: booking.id,
      status: booking.status,
      amount: booking.amount,
      currency: booking.currency,
      payment_status: booking.payment_status,
      # A free first session, booked by the desk with no contract.
      trial: booking.trial,
      created_at: booking.created_at,
      covered_by: covered_by,
      client: {
        id: booking.client.id,
        full_name: booking.client.full_name,
        email: booking.client.email,
        phone: booking.client.phone
      },
      session: {
        id: booking.session.id,
        starts_at: booking.session.starts_at,
        ends_at: booking.session.ends_at,
        status: booking.session.status,
        activity_name: booking.session.activity.name,
        activity_emoji: booking.session.activity.emoji,
        company_id: booking.session.company_id,
        company_name: booking.session.company.name,
        coach_name: booking.session.coach&.full_name
      }
    }
  end

  private

  attr_reader :booking

  def covered_by
    return { type: "contract", name: booking.contract.contract_type.name } if booking.contract
    return { type: "trial" } if booking.trial?

    # Booked by the desk with no contract: a single session, paid on its own.
    { type: "drop_in" }
  end
end
