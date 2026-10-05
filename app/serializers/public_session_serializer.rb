# A session as one of the gym's own members sees it in their app.
#
# Deliberately its own serializer rather than a filtered SessionSerializer:
# that one is for the people who run the gym, and anything added to it later
# — a price, a client, an internal note — would silently reach members here.
# This one can only ever show what is listed below.
class PublicSessionSerializer
  def initialize(session, current_client: nil)
    @session = session
    @current_client = current_client
  end

  def as_json(*)
    {
      id: session.id,
      company_id: session.company_id,
      activity_name: session.activity.name,
      activity_emoji: session.activity.emoji,
      coach_name: session.coach&.full_name,
      # A one-to-one slot (EMS, personal training): the app shows it as an
      # appointment to take rather than a class to join.
      individual: session.activity.individual?,
      space_name: session.space&.name,
      starts_at: session.starts_at,
      ends_at: session.ends_at,
      capacity: session.capacity,
      # How much room is left, never how many people are in it: who else
      # trains here is the gym's business and theirs.
      spots_left: [ session.capacity - session.confirmed_bookings_count, 0 ].max,
      full: session.confirmed_bookings_count >= session.capacity,
      already_booked: already_booked?
    }
  end

  private

  attr_reader :session, :current_client

  def already_booked?
    return false if current_client.nil?

    session.bookings.held.where(client_id: current_client.id).exists?
  end
end
