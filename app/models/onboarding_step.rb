# The setup a company walks through before it can run a day of business.
#
# Code-defined, like Permission: which steps exist is a property of the
# product, not of a tenant. What varies per company is how far through it
# is, and that is derived — see OnboardingState.
#
# Every step is either satisfied by DATA the company owns (it has an
# activity, it has a plan) or, where there is no such data, by the admin
# saying so. Deriving it is what stops the checklist going stale: create an
# activity from the catalogue page and the step ticks itself, because the
# step IS "this company has an activity".
module OnboardingStep
  Step = Struct.new(:key, :skippable, :feature, keyword_init: true) do
    def skippable? = skippable
  end

  ALL = [
    # The name, timezone, currency and opening hours. Nothing in the
    # database can tell us an admin has LOOKED at these — a company is
    # created with defaults for all of them — so this one is confirmed by
    # hand and is the only step that works that way.
    Step.new(key: "company", skippable: false),
    # Nothing can be sold or scheduled until there is something to sell.
    Step.new(key: "activities", skippable: false),
    # Only asked of a company that turned rooms on. A single-room gym never
    # sees this step at all, which is the point of the feature flag.
    Step.new(key: "spaces", skippable: true, feature: :spaces),
    Step.new(key: "plans", skippable: false),
    # A one-person studio is a real business. Skippable, never required.
    Step.new(key: "staff", skippable: true)
  ].freeze

  KEYS = ALL.map(&:key).freeze

  def self.find(key)
    ALL.find { |step| step.key == key.to_s }
  end

  # Keeps only recognised keys, de-duplicated, in catalogue order — used to
  # normalise whatever is stored in or sent to `settings.onboarding`.
  def self.sanitize(keys)
    given = Array(keys).map(&:to_s)
    KEYS.select { |key| given.include?(key) }
  end

  def self.skippable?(key)
    find(key)&.skippable? || false
  end
end
