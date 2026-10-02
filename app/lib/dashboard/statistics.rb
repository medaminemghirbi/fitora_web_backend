module Dashboard
  class Statistics
    # `revenue: false` keeps the volumes and drops every figure in money.
    # A moderator or a moderator chases the eight subscriptions running
    # out this week; what the gym earns is the admin's to read.
    def self.call(company:, revenue: true)
      new(company: company, revenue: revenue).call
    end

    def initialize(company:, revenue: true)
      @company = company
      @revenue = revenue
    end

    def call
      {
        total_clients: company.memberships.active.count,
        active_contracts: company.contract_periods.currently_active.count,
        todays_bookings: todays_bookings.count,
        todays_attendance: todays_attendance_count,
        outstanding_payments: revenue? ? outstanding_payments_total : nil,
        todays_schedule: todays_schedule,
        attention: attention,
        contracts_expiring: contracts_expiring,
        recent_payments: revenue? ? recent_payments : [],
        # Twelve months of takings, for the dashboard's one chart. Behind
        # the same gate as every other figure in money.
        revenue_by_month: revenue? ? Dashboard::Revenue.by_month(company: company) : [],
        recent_clients: recent_clients
      }
    end

    private

    attr_reader :company

    def revenue?
      @revenue
    end

    def base_sessions_scope
      Session.where(company_id: company.id)
    end

    def todays_bookings
      Booking.confirmed.joins(:session).merge(base_sessions_scope).where(sessions: { starts_at: Time.current.all_day })
    end

    def todays_attendance_count
      AttendanceRecord.present.joins(booking: :session).merge(base_sessions_scope)
                       .where(sessions: { starts_at: Time.current.all_day }).count
    end

    def outstanding_payments_total
      unpaid_bookings = Booking.joins(:session).merge(base_sessions_scope)
                                .unpaid.sum(:amount)
      unpaid_contracts = company.contract_periods.unpaid.sum(:final_price)
      unpaid_bookings + unpaid_contracts
    end

    def todays_schedule
      base_sessions_scope
        .where(starts_at: Time.current.all_day)
        .order(:starts_at)
        .includes(:activity, :coach)
        .map do |session|
          {
            id: session.id,
            starts_at: session.starts_at,
            # The caller decides which row is "now" — it knows the clock in
            # the reader's own timezone, which this process does not.
            ends_at: session.ends_at,
            activity_name: session.activity.name,
            activity_emoji: session.activity.emoji,
            coach_name: session.coach&.full_name,
            confirmed_count: session.confirmed_bookings_count,
            capacity: session.capacity,
            status: session.status
          }
        end
    end

    # What a gym admin has to DO today, as opposed to what happened.
    #
    # One row per kind of overdue work, each with the count that makes it
    # worth looking at and — where money is involved — what it is worth. A
    # zero row is still emitted so the caller decides whether to show "all
    # clear" or hide the line; filtering here would make that impossible.
    #
    # `key` names the screen the row opens, so adding a row never means
    # touching the frontend's routing.
    def attention
      expiring = current_periods.expiring_soon(within: 30.days)
      unpaid = current_periods.active.unpaid
      expired = current_periods.active.where(expires_at: ...Time.current)

      [
        { key: "expiring", count: expiring.count, amount: nil, detail: expiring_detail(expiring) },
        { key: "unpaid", count: unpaid.count, amount: revenue? ? unpaid.sum(:final_price).to_f : nil,
          detail: oldest_detail(unpaid, :starts_at) },
        { key: "expired", count: expired.count, amount: nil, detail: oldest_detail(expired, :expires_at) },
        # No detail: "how many sessions today have no coach" is already the
        # count, and there is nothing cheap to add that a reader would act on.
        { key: "sessions_without_coach", count: todays_sessions.where(coach_id: nil).count, amount: nil, detail: nil }
      ]
    end

    # A second line under an attention row, so the number is not the only
    # thing it says. `kind` names the sentence the frontend translates;
    # `count` fills its one placeholder. nil when there is nothing worth
    # adding — a row with no detail simply has no second line.
    def expiring_detail(scope)
      today = scope.where(expires_at: Time.current..Time.current.end_of_day).count
      return nil if today.zero?

      { kind: "expiring_today", count: today }
    end

    # How long the oldest one has been sitting there. "4 unpaid" is a number;
    # "the oldest is 23 days old" is a reason to do something today.
    def oldest_detail(scope, column)
      oldest = scope.minimum(column)
      return nil if oldest.blank?

      days = ((Time.current - oldest) / 1.day).floor
      return nil if days < 1

      { kind: "oldest_days", count: days }
    end

    # Only a contract's LATEST period counts: an expired period from last
    # season is history, not work.
    def current_periods
      company.contract_periods.where(<<~SQL.squish)
        contract_periods.id = (
          SELECT cp2.id FROM contract_periods cp2
          WHERE cp2.contract_id = contract_periods.contract_id
          ORDER BY cp2.starts_at DESC, cp2.created_at DESC LIMIT 1
        )
      SQL
    end

    def todays_sessions
      base_sessions_scope.where(starts_at: Time.current.all_day).where.not(status: :cancelled)
    end

    def contracts_expiring
      company.contract_periods.expiring_soon.includes(contract: %i[client contract_type]).order(:expires_at).limit(5).map do |period|
        { id: period.contract_id, client_name: period.contract.client.full_name, plan_name: period.contract.contract_type.name, expires_at: period.expires_at }
      end
    end

    def recent_payments
      company.payments.paid.recent.includes(:client).limit(5).map do |p|
        { id: p.id, client_name: p.client.full_name, amount: p.amount, currency: p.currency, paid_at: p.paid_at }
      end
    end

    def recent_clients
      # "Recent" is recently joined THIS gym, which is the membership's date,
      # not the day the person's platform account was created.
      company.memberships.includes(:client).order(joined_at: :desc).limit(5).map do |m|
        c = m.client
        { id: c.id, full_name: c.full_name, joined_at: m.joined_at }
      end
    end
  end
end
