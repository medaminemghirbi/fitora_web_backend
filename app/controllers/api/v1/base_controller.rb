module Api
  module V1
    class BaseController < ApplicationController
      before_action :authenticate_request!
      before_action :reject_member_token!
      before_action :require_confirmed_email!
      before_action :enforce_trial_lock!
      # After authentication, so it knows whose gym this is.
      around_action :in_gym_time_zone

      private

      # "Today", a day's end and "18:00 on Tuesday" mean the gym's local
      # time, not the server's UTC. Timestamps are still stored in UTC; only
      # what a date or a wall-clock time means changes.
      def in_gym_time_zone(&action)
        company = current_company || member_company || current_client&.companies&.first
        Time.use_zone(company&.time_zone || Time.zone, &action)
      end

      # A member's token has no business on a staff endpoint.
      #
      # Without this the refusal was incidental: most staff controllers call
      # require_company! early, which renders 422 because a client login has
      # no current_company — denied, but by accident and with a misleading
      # status. Worse, a controller whose capability check runs first would
      # reach `current_user.admin?` with current_user nil and raise.
      #
      # One gate, applied to every staff controller, so a new one is closed
      # by default. The member's own namespace (Api::V1::Me::*) is the single
      # exemption, and it gates on require_client! instead.
      def reject_member_token!
        return if current_client.nil?
        return if self.class.name.to_s.start_with?("Api::V1::Me::")

        render_forbidden
      end

      # An admin who signed up and has not clicked the link yet reaches
      # nothing here — not even naming their gym, which is where the trial
      # starts. What they need meanwhile (who am I, send it again) lives in
      # AuthController and EmailVerificationsController, outside this base.
      #
      # A superadmin impersonating them is let through: they are there to help,
      # and the address is not theirs to confirm.
      def require_confirmed_email!
        return if current_user.nil? || current_impersonator.present?
        return unless current_user.email_confirmation_pending?

        render json: {
          error: "email_unverified",
          message: "Confirm your email address to open your account. We sent the link to #{current_user.email}."
        }, status: :forbidden
      end

      # The only endpoints a locked company's admin can still reach — enough
      # to see their status, and nothing that operates the gym. Staff get no
      # exceptions at all: once the free trial expires, only the admin has
      # any access, and only to this much, until a platform superadmin manually
      # grants access again (Api::V1::Superadmin::CompaniesController#update_subscription).
      ADMIN_ALLOWED_WHEN_LOCKED = {
        # A locked admin still sees what they owe and can download the
        # invoices they already have: the way out is settling, and both of
        # these are how they work out what settling means.
        "Api::V1::SubscriptionController" => %w[show],
        "Api::V1::InvoicesController" => %w[index show],
        # Their salles are still theirs to see and move between while the
        # account is locked.
        "Api::V1::CompaniesController" => %w[show index switch]
      }.freeze
      private_constant :ADMIN_ALLOWED_WHEN_LOCKED

      def enforce_trial_lock!
        # A member's own login carries no current_user. Their gym's trial
        # status is not their problem to see: the member app has no "locked"
        # screen, and leaving them stranded mid-booking would teach them
        # nothing they can act on.
        return if current_client
        return if current_user.superadmin?

        subscription = current_company&.subscription
        return unless subscription&.locked?

        return if current_user.admin? && ADMIN_ALLOWED_WHEN_LOCKED[self.class.name]&.include?(action_name)

        render json: {
          error: subscription.lock_reason.to_s,
          message: lock_message(subscription)
        }, status: :payment_required
      end

      # Why the door is shut, in words the person reading them can act on.
      # Staff are told to talk to their admin whatever the reason: the money
      # is not theirs to settle and the detail is not theirs to see.
      def lock_message(subscription)
        return "This gym's account is locked. Contact your gym's admin." unless current_user.admin?

        reason = subscription.lock_reason
        if reason == :unpaid && subscription.trial?
          "Your free trial has ended. Choose Starter or Pro and settle with Fitora to reopen access."
        elsif reason == :unpaid
          "The period you paid for has run out. Access closed #{Subscription::GRACE_DAYS} days later; settle with Fitora to reopen it."
        else
          "Your access has been suspended by Fitora. Get in touch to find out why."
        end
      end

      # Never trust a company_id supplied by the client — always derive
      # it from the authenticated user: an admin runs several salles and a
      # staff login may be posted to several, so it is whichever one the
      # session switched to (Api::V1::CompaniesController#switch), and for
      # staff only ever one it still works in (User#current_company). Never
      # confuse either with User#role == "superadmin", the Fitora platform
      # operator handled entirely by Api::V1::Superadmin::*.
      def current_company
        @current_company ||= current_user&.current_company
      end

      # For a member's login: the gyms whose app they can use — the ones
      # they belong to whose account includes the member app (Pro, or a
      # free trial). A Starter gym's members have no app to open.
      def member_companies
        @member_companies ||= (current_client&.companies&.includes(admin: { subscription: :invoices }) || []).select(&:member_app?)
      end

      # For a member's login: the gym named by ?company_id=, checked against
      # the gyms whose app they can use. nil means "every such gym" —
      # almost always exactly one.
      def member_company
        return @member_company if defined?(@member_company)

        @member_company = if params[:company_id].present?
          member_companies.find { |c| c.id == params[:company_id].to_s }
        end
      end

      # The member app is a Pro feature: a member none of whose gyms is on
      # Pro (or trying Fitora) has nothing to open.
      def require_member_app!
        return if member_companies.any?

        render json: {
          error: "member_app_not_included",
          message: "Your gym's plan does not include the member app."
        }, status: :forbidden
      end

      # 404 rather than 403: a gym the person has not joined should not even
      # be distinguishable from one that does not exist.
      def require_member_company!
        return if params[:company_id].blank? || member_company

        render json: { error: "Gym not found" }, status: :not_found
      end

      def current_staff_member
        return nil unless current_user&.staff?

        @current_staff_member ||= current_user.staff_member
      end

      def require_admin!
        render_forbidden unless current_user.admin?
      end

      def require_superadmin!
        render_forbidden unless current_user.superadmin?
      end

      # Gates the member endpoints (Api::V1::Me::*) — the counterpart to
      # require_admin!/require_superadmin!, for the other kind of login.
      def require_client!
        render_forbidden if current_client.nil?
      end

      # True for the admin (always) or for staff whose role grants this
      # capability — the only two ways into any endpoint gated by this check.
      def require_capability!(capability)
        render_forbidden unless capability?(capability)
      end

      # The same test without the rendering, for an action that has to make
      # the check somewhere other than a before_action — render_forbidden
      # does not halt, so calling require_capability! mid-action would render
      # twice.
      def capability?(capability)
        return true if current_user.admin?

        current_staff_member&.active? && current_staff_member.can?(capability) || false
      end

      # Anyone with a seat in the company can see the calendar — the schedule is
      # shared operational context for every role. Editing sessions is a
      # separate, narrower check (require_capability!(:sessions)).
      def require_staff!
        return if current_user.admin?
        return if current_staff_member&.active?

        render_forbidden
      end

      # Read access to the reference data a session is built from (the activity
      # catalogue, the opening hours): whoever owns that data
      # (`capability`) *plus* anyone who can edit the schedule (`:sessions`),
      # since you can't plan a week of sessions without seeing the options.
      def require_schedule_reference_read!(capability)
        return if current_user.admin?
        if current_staff_member&.active? &&
           (current_staff_member.can?(capability) || current_staff_member.can?(:sessions))
          return
        end

        render_forbidden
      end

      def require_company!
        render json: { error: "No company found for this account" }, status: :unprocessable_content if current_company.nil?
      end

      def paginate(scope)
        page, per_page = page_params
        scope.limit(per_page).offset((page - 1) * per_page)
      end

      def pagination_meta(scope)
        page, per_page = page_params
        total = scope.count

        { page: page, per_page: per_page, total: total, total_pages: (total.to_f / per_page).ceil }
      end

      # ?page= from 1, ?per_page= 20 by default and never more than 100.
      def page_params
        page = [ params[:page].to_i, 1 ].max
        per_page = params[:per_page].to_i
        per_page = 20 if per_page <= 0
        [ page, [ per_page, 100 ].min ]
      end
    end
  end
end
