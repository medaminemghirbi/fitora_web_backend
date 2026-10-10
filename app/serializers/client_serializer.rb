class ClientSerializer
  # `company` is the gym looking at this person. It is what scopes their
  # contracts, money and attendance to that gym, and where "active", "joined"
  # and the gym's private notes come from — those belong to the membership,
  # not to the person. Passing nil is the person's own, cross-gym view.
  # `last_visit_at` is passed in rather than computed here: on a list it is
  # one grouped query for the whole page (see
  # Api::V1::ClientsController#last_visits_for), and computing it per record
  # would make that impossible.
  # A list passes `membership` and `current_contract` in too, loaded for the
  # whole page at once (see .page_context); on its own a row would look each
  # up itself — a membership and a contract per member.
  # `reveal`: the whole e-mail address — the person's own session only.
  # Anyone else gets it masked (EmailMask).
  def initialize(client, detailed: false, company: nil, last_visit_at: :unset, membership: :unset, current_contract: :unset, reveal: false)
    @client = client
    @reveal = reveal
    @detailed = detailed
    @company = company
    @membership = membership == :unset ? company && client.membership_for(company) : membership
    @current_contract = current_contract
    @last_visit_at = last_visit_at
  end

  # Everything a list of these reads, for a whole page, in three queries.
  def self.page_context(clients, company)
    ids = clients.map(&:id)
    contracts = company.contracts.for_serializer
                       .where(client_id: ids)
                       .currently_active
                       .order(Client::CURRENT_CONTRACT_ORDER)
                       .to_a
    {
      memberships: company.memberships.where(client_id: ids).index_by(&:client_id),
      current_contracts: contracts.group_by(&:client_id).transform_values(&:first)
    }
  end

  def as_json(*)
    base = {
      id: client.id,
      first_name: client.first_name,
      last_name: client.last_name,
      full_name: client.full_name,
      login_enabled: client.login_enabled?,
      email: @reveal ? client.email : EmailMask.call(client.email),
      phone: client.phone,
      active: membership ? membership.active : client.active,
      joined_at: membership&.joined_at,
      current_contract: ContractSerializer.new(current_contract).as_json
    }

    # Only when the caller supplied it. A list sends it; anything that did
    # not ask gets no key at all rather than a misleading null.
    base[:last_visit_at] = @last_visit_at unless @last_visit_at == :unset

    return base unless detailed

    base.merge(
      # This gym's own copy — another gym that knows the same person never
      # sees it (see Membership).
      date_of_birth: membership&.date_of_birth,
      gender: membership&.gender,
      address: membership&.address,
      emergency_contact_name: membership&.emergency_contact_name,
      emergency_contact_phone: membership&.emergency_contact_phone,
      notes: membership&.notes,
      health_notes: membership&.health_notes,
      waiver_signed_on: membership&.waiver_signed_on,
      # Name, email and phone are the person's once they sign in or train
      # elsewhere; the form locks them rather than letting a save bounce.
      identity_locked: company ? client.identity_shared_beyond?(company) : true,
      invitation_pending: client.invitation_pending?,
      invited_at: client.invitation_sent_at,
      outstanding_balance: client.outstanding_balance(company),
      attendance_rate: client.attendance_rate(company),
      last_visit_at: @last_visit_at == :unset ?
        client.bookings_for(company).confirmed.joins(:session).maximum("sessions.starts_at") :
        @last_visit_at
    )
  end

  private

  attr_reader :client, :detailed, :company, :membership

  def current_contract
    @current_contract == :unset ? client.current_contract(company) : @current_contract
  end
end
