# Where a company is in first-time setup, and what it should do next
# (Company#onboarding_state).
#
# Resumable by construction: nothing here is remembered except the two
# facts no table holds (a step confirmed by hand, a step declined). Every
# other step reads the company's own data, so setup survives a logout, a
# different browser and a step completed from somewhere else entirely.
#
# A step whose feature is off is not skipped, not pending and not late —
# it does not exist for this company. Asking a one-room gym which room a
# session is in is a question with one answer.
class OnboardingState
  def initialize(company)
    @company = company
    @stored = company.settings.onboarding
    @steps = OnboardingStep::ALL.select { |step| applicable?(step) }.map { |step| build(step) }.freeze
    mark_current
    freeze
  end

  attr_reader :steps

  # What the admin should be looking at. "done" once nothing is pending.
  def current_key
    pending = steps.find { |step| step[:state] == "current" }
    pending ? pending[:key] : "done"
  end

  def complete?
    steps.none? { |step| step[:state] == "current" || step[:state] == "todo" }
  end

  def dismissed?
    @company.setup_dismissed_at.present?
  end

  def as_json(*)
    {
      step: current_key,
      complete: complete?,
      dismissed: dismissed?,
      done_count: steps.count { |step| step[:state] == "done" },
      total: steps.length,
      steps: steps
    }
  end

  private

  def applicable?(step)
    step.feature.nil? || @company.feature?(step.feature)
  end

  def build(step)
    satisfied = satisfied?(step.key)
    confirmed = satisfied || @stored[:completed].include?(step.key)
    skipped = !confirmed && @stored[:skipped].include?(step.key)

    {
      key: step.key,
      skippable: step.skippable?,
      # "done" means the company has what the step asks for. "skipped"
      # means it said it does not need it — a different answer, shown
      # differently, and reversible.
      state: confirmed ? "done" : (skipped ? "skipped" : "todo"),
      count: count_for(step.key)
    }
  end

  # Exactly one "todo" is the one being asked for; the rest stay "todo" so
  # the flow reads as a list rather than a queue of locked doors. An admin
  # who wants to do plans before activities is not wrong.
  def mark_current
    first = @steps.find { |step| step[:state] == "todo" }
    first[:state] = "current" if first
    @steps.each(&:freeze)
  end

  def satisfied?(key)
    case key
    when "company" then false # confirmed by hand; see OnboardingStep
    when "activities" then @company.activities.exists?
    when "spaces" then @company.spaces.exists?
    when "plans" then @company.contract_types.exists?
    when "staff" then @company.staff_members.exists? || @company.coaches.exists?
    else false
    end
  end

  # How many of the thing the step is about already exist — so the flow
  # can say "3 activities" rather than only "done".
  def count_for(key)
    case key
    when "activities" then @company.activities.count
    when "spaces" then @company.spaces.count
    when "plans" then @company.contract_types.count
    when "staff" then @company.staff_members.count + @company.coaches.count
    else nil
    end
  end
end
