# frozen_string_literal: true

module RuboCop
  module Cop
    module Fitora
      # Flags `SomeTenantModel.find(...)` / `.find_by(...)` / `.find_by!(...)`
      # / `.where(...)` called directly on a class known to belong to a
      # Company (directly, or through the location/session/contract chain it
      # sits in) — the fix is almost always going through `current_company`
      # instead (e.g. `current_company.clients.find(...)`).
      #
      # This exists because of a real bug: Api::V1::BookingsController#set_booking
      # used to do a bare `Booking.find(params[:id])`. It happened to be safe
      # in practice only because BookingPolicy#show? separately re-checked
      # the company match — but any new action on `@booking` that forgot to
      # call the policy first would have been a live cross-tenant leak. A
      # single missed check on one future endpoint is exactly the failure
      # mode this cop exists to make impossible to merge.
      #
      # Exempt: app/controllers/api/v1/superadmin/** — Fitora's own console is
      # deliberately cross-tenant by design (it manages every company).
      class UnscopedTenantQuery < RuboCop::Cop::Base
        MSG = "%<receiver>s.%<method>s is unscoped — a cross-tenant data leak waiting to happen if nothing else " \
              "re-checks the company match. Scope it through current_company instead of calling " \
              "%<receiver>s directly (e.g. current_company.<association>.%<method>s(...))."

        # Every model that belongs to a company, directly or through an
        # association chain (session -> location -> company, etc.) — kept in
        # sync by hand; a new tenant-scoped model should be added here.
        # Deliberately NOT here: Company itself (the tenant root — finding a
        # bare Company is how you resolve a tenant in the first place, e.g.
        # PairingController) and User (login has to search by email across
        # everyone, unauthenticated, before any company is known).
        TENANT_MODELS = %w[
          Client Booking Session Activity Coach Membership
          StaffMember Contract ContractType
          ContractTypeActivity Payment Space ActivitySpace
          AttendanceRecord RecurringSchedule SupportTicket Role
          AuditLog Notification DataImport
        ].freeze

        RESTRICT_ON_SEND = %i[find find_by find_by! where].freeze

        def_node_matcher :unscoped_tenant_query?, <<~PATTERN
          (send (const {nil? cbase} #tenant_model?) ...)
        PATTERN

        def on_send(node)
          return unless node.receiver
          return unless unscoped_tenant_query?(node)
          return if superadmin_namespace?
          return if merge_condition_fragment?(node)

          receiver_name = node.receiver.const_name
          add_offense(node, message: format(MSG, receiver: receiver_name, method: node.method_name))
        end

        private

        def tenant_model?(name)
          TENANT_MODELS.include?(name.to_s)
        end

        # `outer_scope.merge(TenantModel.where(...))` never independently
        # fetches anything — `.where` here only contributes a condition
        # fragment to whatever `outer_scope` already is, so it's exactly as
        # scoped as that outer relation. Only exempts `.where`: `.find`/
        # `.find_by` always return an actual record on their own and are
        # never legitimately a merge argument.
        def merge_condition_fragment?(node)
          node.method?(:where) && node.parent&.send_type? && node.parent.method?(:merge)
        end

        def superadmin_namespace?
          processed_source.path.to_s.include?("/controllers/api/v1/superadmin/")
        end
      end
    end
  end
end
