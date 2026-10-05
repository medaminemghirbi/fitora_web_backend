module Api
  module V1
    class ContractTypesController < BaseController
      before_action :require_company!
      # Reading the plan list is part of signing a member up (:contracts);
      # editing the catalogue — prices, session counts — is configuration.
      before_action -> { require_capability!(:contracts) }, only: [ :index, :show ]
      before_action -> { require_capability!(:contract_types) }, only: [ :create, :update ]
      before_action :set_plan, only: [ :show, :update ]

      # GET /api/v1/contract_types
      def index
        # Was ordered by the flat price, which no longer exists — a plan now
        # has one price per activity. Shortest commitment first, then name.
        plans = current_company.contract_types
                               .preload({ contract_type_activities: :activity }, { contract_type_packs: { pack: :activities } })
                               .order(:billing_period, :name)
        render json: { plans: plans.map { |p| ContractTypeSerializer.new(p).as_json } }
      end

      # GET /api/v1/contract_types/:id
      def show
        render json: { plan: ContractTypeSerializer.new(@plan).as_json }
      end

      # POST /api/v1/contract_types
      def create
        plan = current_company.contract_types.new(plan_params)

        if plan.save
          sync_associations(plan)
          render json: { plan: ContractTypeSerializer.new(plan).as_json }, status: :created
        else
          render_errors(plan)
        end
      end

      # PATCH /api/v1/contract_types/:id
      def update
        if @plan.update(plan_params)
          sync_associations(@plan)
          render json: { plan: ContractTypeSerializer.new(@plan).as_json }
        else
          render_errors(@plan)
        end
      end

      private

      def set_plan
        @plan = current_company.contract_types.find(params[:id])
      end

      # The plan's pricing grid: one { activity_id, price } per activity this
      # plan is sold for. Activities not listed are dropped — the plan simply
      # isn't offered for them. Ids from another company are ignored, same
      # guard the old activity_ids sync used.
      def sync_associations(plan)
        sync_activity_prices(plan)
        sync_pack_prices(plan)
      end

      def sync_activity_prices(plan)
        return unless params.key?(:activity_prices)

        own_activity_ids = current_company.activities.ids
        rows = Array(params[:activity_prices]).filter_map do |row|
          activity_id = row[:activity_id].presence
          next unless own_activity_ids.include?(activity_id)

          { activity_id: activity_id, price: row[:price].to_f }
        end

        plan.contract_type_activities.where.not(activity_id: rows.map { |r| r[:activity_id] }).destroy_all
        rows.each do |row|
          plan.contract_type_activities.find_or_initialize_by(activity_id: row[:activity_id]).update!(price: row[:price])
        end
      end

      # The same grid for packs. Sent on its own so a caller pricing one
      # activity doesn't have to restate every pack, and vice versa: a list
      # that is absent is left alone, an empty one clears the plan's packs.
      def sync_pack_prices(plan)
        return unless params.key?(:pack_prices)

        own_pack_ids = current_company.packs.ids
        rows = Array(params[:pack_prices]).filter_map do |row|
          pack_id = row[:pack_id].presence
          next unless own_pack_ids.include?(pack_id)

          { pack_id: pack_id, price: row[:price].to_f }
        end

        plan.contract_type_packs.where.not(pack_id: rows.map { |r| r[:pack_id] }).destroy_all
        rows.each do |row|
          plan.contract_type_packs.find_or_initialize_by(pack_id: row[:pack_id]).update!(price: row[:price])
        end
      end

      # Optional, so the pricing grid can send a formule's prices alone. A
      # create without it still fails, on the name.
      def plan_params
        params.fetch(:contract_type, {}).permit(
          :name, :description, :billing_period, :validity_days, :session_count,
          :unlimited_bookings, :booking_limit, :priority_booking, :active, :color
        )
      end
    end
  end
end
