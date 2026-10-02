# How a company has configured the engine to behave.
#
# Gymly runs a boxing club, a Pilates studio, an EMS studio and a gym off
# one codebase. The difference between them is not a `type` column and not a
# branch in the code — it is the values in here. A studio turns rooms on and
# gives itself a twelve-hour cancellation window; a gym leaves rooms off and
# never asks anyone to book at all.
#
# The surface is deliberately CLOSED. The *values* are per-company; the
# *keys* are code. Anything not declared in SCHEMA is dropped on write, so a
# stray key from a client, a half-finished feature or an old release can
# never accumulate in the column. Read #unknown_keys if you need to know what
# a write threw away.
#
# What belongs here: rules and toggles. What does not: anything you would
# ever query, join or constrain on. A member, a booking, a payment, a space
# is a row in a table. A cancellation window is a value in here. See
# docs/TARGET_ARCHITECTURE.md §2.
#
# Immutable: #merge returns a new instance rather than mutating, so a
# settings object handed to a service cannot be changed under it.
class CompanySettings
  # A feature flag says what the product OFFERS this company. It never
  # grants anyone access to anything — permissions are a separate, orthogonal
  # check (see Permission / Role). Turning a feature on must never widen a
  # role. See docs/PERMISSIONS.md §1.
  FEATURES = {
    # Whether sessions can be booked at all. A gym selling unlimited access
    # with a turnstile and no classes turns this off and never sees a
    # booking screen.
    bookings: true,
    # Rooms. Off by default: most gyms are one space, and asking them which
    # room a session is in would be a question with one answer. A Pilates
    # studio with two studios, or an EMS place with four cabins, turns it on.
    spaces: false,
    # Check-in / attendance tracking.
    attendance: true,
    # Whether the product surfaces money at all. Distinct from the `revenue`
    # permission, which decides WHO sees it.
    revenue: true,
    reports: true,
    # Whether members may book themselves from their own app, or whether
    # booking is something the front desk does for them.
    online_booking: true,
    # Whether a full session takes a queue. Off by default: a waitlist nobody
    # manages is worse than a full session.
    waitlist: false
  }.freeze

  # The rules that govern booking, once `features.bookings` is on.
  BOOKING = {
    # How many hours before a session a member may still cancel and get
    # their session credit back. 0 means "right up to the start".
    cancellation_hours: { default: 2, min: 0, max: 168 },
    # How far ahead the schedule is bookable. Stops a member filling every
    # session for the next year.
    booking_opens_days: { default: 14, min: 1, max: 365 },
    # Whether failing to turn up still costs a session off the member's
    # balance. Most places say yes; it is the only thing that makes a
    # no-show cost anything.
    no_show_consumes_session: { default: true }
  }.freeze

  # When the business is open. Used to lay out the calendar and to stop a
  # session being scheduled on a day the place is shut. Times are "HH:MM"
  # strings; working_days are Date#wday values (0 = Sunday).
  HOURS = {
    start: "06:00",
    end: "22:00",
    working_days: [ 1, 2, 3, 4, 5 ]
  }.freeze

  # White-label appearance. primary_color overrides --color-primary in the
  # app; nil means "use Gymly's own".
  BRANDING = {
    primary_color: nil
  }.freeze

  # How far through first-time setup this company is. Two lists of step
  # keys, and nothing else: every step that CAN be derived from data is
  # derived (see OnboardingState), so the only things worth storing are
  # the two answers no table holds — "I have looked at this" and "I do not
  # need this". Progress rather than a rule, which is why it is the one
  # section here that is not a setting; it lives with them because it is
  # per-company, closed-schema and nothing would ever join on it.
  ONBOARDING = {
    completed: [],
    skipped: []
  }.freeze

  TIME_FORMAT = /\A([01]\d|2[0-3]):[0-5]\d\z/
  HEX_COLOR = /\A#[0-9a-fA-F]{6}\z/

  SECTIONS = %i[features booking hours branding onboarding].freeze

  attr_reader :unknown_keys

  # Keys whose supplied value was present but unusable — an invalid hex
  # colour, a weekday that is not a weekday, an empty list of opening days.
  # The value falls back to its default so the object is always coherent,
  # and Company turns this list into validation errors so the person who
  # typed it finds out, rather than watching it silently vanish.
  attr_reader :invalid_values

  def self.default
    new({})
  end

  def initialize(raw)
    raw = {} unless raw.is_a?(Hash)
    raw = raw.deep_symbolize_keys
    @unknown_keys = []
    @invalid_values = []

    @features = build_features(raw[:features])
    @booking = build_booking(raw[:booking])
    @hours = build_hours(raw[:hours])
    @branding = build_branding(raw[:branding])
    @onboarding = build_onboarding(raw[:onboarding])
    collect_unknown_sections(raw)

    freeze
  end

  # --- Features -------------------------------------------------------------

  # `company.settings.feature?(:spaces)` — the one way to ask.
  def feature?(key)
    @features.fetch(key.to_sym, false)
  end

  def features
    @features
  end

  # --- Booking rules --------------------------------------------------------

  def booking
    @booking
  end

  def cancellation_hours = @booking[:cancellation_hours]
  def booking_opens_days = @booking[:booking_opens_days]
  def no_show_consumes_session? = @booking[:no_show_consumes_session]

  # --- Opening hours --------------------------------------------------------

  def hours = @hours

  def business_hours_start = @hours[:start]
  def business_hours_end = @hours[:end]
  def working_days = @hours[:working_days]

  # True when the business operates on the given date's weekday.
  def working_day?(date)
    working_days.include?(date.wday)
  end

  # --- Branding -------------------------------------------------------------

  def branding = @branding

  def primary_color = @branding[:primary_color]

  # --- Onboarding progress --------------------------------------------------

  def onboarding = @onboarding

  def onboarding_completed = @onboarding[:completed]
  def onboarding_skipped = @onboarding[:skipped]

  # --- Reading and writing --------------------------------------------------

  def to_h
    { features: @features, booking: @booking, hours: @hours, branding: @branding, onboarding: @onboarding }
  end

  # Returns a NEW settings object with `patch` applied on top. Only the keys
  # present in the patch change; everything else keeps its current value, so
  # a form that edits one section cannot silently reset another.
  def merge(patch)
    patch = {} unless patch.is_a?(Hash)
    patch = patch.deep_symbolize_keys

    self.class.new(
      features: @features.merge(section(patch, :features)),
      booking: @booking.merge(section(patch, :booking)),
      hours: @hours.merge(section(patch, :hours)),
      branding: @branding.merge(section(patch, :branding)),
      onboarding: @onboarding.merge(section(patch, :onboarding))
    )
  end

  def ==(other)
    other.is_a?(self.class) && to_h == other.to_h
  end
  alias eql? ==

  def hash = to_h.hash

  private

  def section(patch, key)
    patch[key].is_a?(Hash) ? patch[key] : {}
  end

  def build_hours(given)
    given = {} unless given.is_a?(Hash)
    note_unknown(given.keys - HOURS.keys, "hours")

    {
      start: cast_time(given[:start], HOURS[:start], "hours.start"),
      end: cast_time(given[:end], HOURS[:end], "hours.end"),
      working_days: cast_working_days(given[:working_days])
    }.freeze
  end

  # The lists replace wholesale on merge rather than accumulating: the
  # caller always sends the list it wants, so un-skipping a step is the
  # same operation as skipping one.
  def build_onboarding(given)
    given = {} unless given.is_a?(Hash)
    note_unknown(given.keys - ONBOARDING.keys, "onboarding")

    {
      completed: OnboardingStep.sanitize(given[:completed]).freeze,
      skipped: OnboardingStep.sanitize(given[:skipped]).freeze
    }.freeze
  end

  def build_branding(given)
    given = {} unless given.is_a?(Hash)
    note_unknown(given.keys - BRANDING.keys, "branding")

    { primary_color: cast_color(given[:primary_color]) }.freeze
  end

  # Accepts "HH:MM" and the "2000-01-01 06:00:00" a Time column used to
  # serialize to, so a value read back from the old column still lands.
  def cast_time(value, default, key)
    return default if value.nil?
    return value if value.is_a?(String) && value.match?(TIME_FORMAT)

    formatted = value.respond_to?(:strftime) ? value.strftime("%H:%M") : value.to_s[/\d{2}:\d{2}/]
    return formatted if formatted&.match?(TIME_FORMAT)

    note_invalid(key)
    default
  end

  # Date#wday values, de-duplicated and sorted. A list that ends up empty
  # falls back to the default rather than closing the business every day.
  def cast_working_days(value)
    return HOURS[:working_days] if value.nil?

    given = Array(value)
    days = given.filter_map { |d| Integer(d, exception: false) }
                .select { |d| d.between?(0, 6) }.uniq.sort

    # Either nothing usable came through, or something in the list was not a
    # weekday. Both are worth telling the person about.
    note_invalid("hours.working_days") if days.empty? || days.length != given.uniq.length

    days.presence || HOURS[:working_days]
  end

  def cast_color(value)
    return nil if value.blank?
    return value.to_s if value.to_s.match?(HEX_COLOR)

    note_invalid("branding.primary_color")
    nil
  end

  def build_features(given)
    given = {} unless given.is_a?(Hash)
    note_unknown(given.keys - FEATURES.keys, "features")

    FEATURES.each_with_object({}) do |(key, default), out|
      out[key] = given.key?(key) ? cast_boolean(given[key], default) : default
    end.freeze
  end

  def build_booking(given)
    given = {} unless given.is_a?(Hash)
    note_unknown(given.keys - BOOKING.keys, "booking")

    BOOKING.each_with_object({}) do |(key, rule), out|
      out[key] = if !given.key?(key)
        rule[:default]
      elsif rule[:default].in?([ true, false ])
        cast_boolean(given[key], rule[:default])
      else
        cast_integer(given[key], rule)
      end
    end.freeze
  end

  # Accepts what a JSON body or an HTML form actually sends — true/false,
  # "true"/"false", 1/0 — and falls back to the default for anything else
  # rather than quietly turning a typo into `false`.
  def cast_boolean(value, default)
    case value
    when true, false then value
    when "true", "1", 1 then true
    when "false", "0", 0 then false
    else default
    end
  end

  # Clamps rather than rejects: a cancellation window of 10_000 hours is a
  # mistake, not an attack, and the nearest legal value is a better answer
  # than a 422 on a settings form.
  def cast_integer(value, rule)
    parsed = Integer(value, exception: false)
    return rule[:default] if parsed.nil?

    parsed.clamp(rule[:min], rule[:max])
  end

  def collect_unknown_sections(raw)
    note_unknown(raw.keys - SECTIONS, nil)
    @unknown_keys.freeze
    @invalid_values.freeze
  end

  def note_invalid(key)
    @invalid_values << key
  end

  def note_unknown(keys, section)
    keys.each { |key| @unknown_keys << [ section, key ].compact.join(".") }
  end
end
