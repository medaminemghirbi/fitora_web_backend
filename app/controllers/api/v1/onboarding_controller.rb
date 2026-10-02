module Api
  module V1
    # First-time setup, as a flow the server tracks rather than a checklist
    # the client remembers. An admin who closes the tab halfway through
    # comes back to the same step, on any device.
    #
    # Admin-only: this is the shape of the business, not its day-to-day.
    # Creating the activities, plans and staff the steps ask for happens on
    # their own endpoints, behind their own capability checks — nothing is
    # written here except how far along the admin is.
    class OnboardingController < BaseController
      before_action :require_admin!
      before_action :require_company!
      before_action :load_step, only: [ :update, :skip ]

      # GET /api/v1/onboarding
      def show
        render_state
      end

      # PATCH /api/v1/onboarding — "I have done this one."
      #
      # Only meaningful for a step nothing in the database can confirm; for
      # every other step the data is the answer, and marking it done while
      # the company still has no activities would be a lie the flow would
      # then have to tell the admin.
      def update
        save_onboarding(completed: current_settings[:completed] | [ @step.key ],
                        skipped: current_settings[:skipped] - [ @step.key ])
      end

      # POST /api/v1/onboarding/skip — "I do not need this one."
      def skip
        unless @step.skippable?
          return render json: { error: "This step cannot be skipped" }, status: :unprocessable_content
        end

        save_onboarding(completed: current_settings[:completed] - [ @step.key ],
                        skipped: current_settings[:skipped] | [ @step.key ])
      end

      # POST /api/v1/onboarding/dismiss — leave the flow. The steps that
      # remain stay remaining; this only stops the app asking. The page is
      # still reachable from Settings, which is why nothing is cleared.
      def dismiss
        current_company.update!(setup_dismissed_at: Time.current)
        render_state
      end

      private

      def load_step
        @step = OnboardingStep.find(params[:step])
        render json: { error: "Unknown step" }, status: :unprocessable_content if @step.nil?
      end

      def current_settings
        current_company.settings.onboarding
      end

      def save_onboarding(completed:, skipped:)
        current_company.settings = { onboarding: { completed: completed, skipped: skipped } }
        current_company.save!
        render_state
      end

      def render_state
        render json: { onboarding: current_company.reload.onboarding_state.as_json }
      end
    end
  end
end
