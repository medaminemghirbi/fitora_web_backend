module Api
  module V1
    module Me
      # What a member can read about themselves: which gym they belong to,
      # the subscription they are training on, and whether they have been
      # turning up.
      #
      # Deliberately not ClientSerializer/ContractSerializer — those are the
      # gym's view and carry prices, discounts and payment status. What a
      # member is owed is between them and the desk, not something their app
      # quotes back at them.
      class ProfilesController < BaseController
        before_action :require_client!
        before_action :require_member_app!, only: [ :show ]
        before_action :require_member_company!

        # GET /api/v1/me/profile?company_id=
        def show
          company = member_company || member_companies.first

          render json: {
            client: {
              id: current_client.id,
              full_name: current_client.full_name,
              first_name: current_client.first_name,
              last_name: current_client.last_name,
              email: current_client.email,
              phone: current_client.phone
            },
            gyms: member_companies.map { |c| { id: c.id, name: c.name } },
            subscription: subscription_json(company),
            attendance: attendance_json(company)
          }
        end

        # PATCH /api/v1/me/profile — { client: { first_name, last_name, phone } }
        #
        # The identity a gym can no longer change once it is shared
        # (Client#identity_shared_beyond?) is the person's own to keep right.
        # The email stays put: it is the login, and changing it would need
        # the new address confirmed first.
        def update
          current_client.update!(params.require(:client).permit(:first_name, :last_name, :phone))
          render json: {
            client: {
              id: current_client.id, full_name: current_client.full_name,
              first_name: current_client.first_name, last_name: current_client.last_name,
              email: current_client.email, phone: current_client.phone
            }
          }
        end

        private

        def subscription_json(company)
          contract = current_client.current_contract(company)
          return nil if contract.nil?

          {
            plan_name: contract.contract_type.name,
            activity_name: contract.activity_label,
            activity_emoji: contract.activity&.emoji,
            all_access: contract.all_access?,
            starts_at: contract.starts_at,
            expires_at: contract.expires_at,
            # nil means the plan is unlimited, not that none are left.
            remaining_bookings: contract.remaining_bookings
          }
        end

        def attendance_json(company)
          attended = current_client.bookings_for(company)
                                    .joins(:attendance_record, :session)
                                    .where(attendance_records: { status: :present })
                                    .order("sessions.starts_at DESC")
                                    .limit(20)

          {
            rate: current_client.attendance_rate(company),
            recent: attended.map do |booking|
              {
                id: booking.id,
                activity_name: booking.session.activity.name,
                activity_emoji: booking.session.activity.emoji,
                starts_at: booking.session.starts_at
              }
            end
          }
        end
      end
    end
  end
end
