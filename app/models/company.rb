class Company < ApplicationRecord
  # Same allowlist/ceiling as HasPhoto — logo is the one has_one_attached in
  # the app that predates that concern and had no validation at all.
  # content_type below is Marcel-sniffed by Active Storage, not the
  # client-declared header, so a renamed .html/.svg can't pass as an image.
  ALLOWED_LOGO_TYPES = %w[image/jpeg image/png image/webp].freeze
  MAX_LOGO_SIZE = 10.megabytes

  # The company's display language — one setting for the whole tenant, set by
  # a Gymly superadmin (Api::V1::Superadmin::CompaniesController#update_settings). The
  # frontend applies it from the bootstrap payload; there is no per-user
  # language switch inside a company's app.
  LOCALES = %w[fr en ar].freeze

  belongs_to :admin, class_name: "User", inverse_of: :companies

  # White-label branding — logo shown in the admin/coach shells, primary_color
  # overrides --color-primary (see BrandingService on the frontend, which
  # derives hover/soft tones from it via CSS color-mix() rather than storing
  # them separately). slug is unused today; it's reserved so hostname-based
  # tenant resolution can be added later without another migration.
  has_one_attached :logo

  validate :logo_is_an_image
  validate :logo_is_not_too_large

  has_many :coaches, dependent: :destroy
  has_many :activities, dependent: :destroy
  has_many :spaces, dependent: :destroy
  has_many :sessions, dependent: :destroy
  has_many :recurring_schedules, dependent: :destroy
  has_many :memberships, dependent: :destroy
  has_many :clients, through: :memberships
  has_many :contract_types, dependent: :destroy
  has_many :contracts, dependent: :destroy
  has_many :contract_periods, through: :contracts
  has_many :data_imports, dependent: :destroy
  has_many :payments, dependent: :destroy
  has_many :staff_members, dependent: :destroy
  has_many :roles, dependent: :destroy
  has_many :audit_logs, dependent: :destroy
  has_many :notifications, dependent: :destroy
  has_many :support_tickets, dependent: :destroy

  # Keeps the column saying exactly what CompanySettings declares — every
  # key present, nothing extra. Without it a company created after the
  # backfill migration sits on `{}` and reads its hours from the defaults:
  # correct behaviour, but a column that no longer describes the company,
  # and a post-migration audit that cannot tell "defaulted" from "lost".
  before_save :normalize_settings

  # CompanySettings coerces anything unusable back to its default so the
  # object is always coherent; this is what stops that being silent.
  validate :settings_values_are_usable

  validates :name, presence: true
  validates :timezone, presence: true
  validate :timezone_is_known
  validates :currency, presence: true, inclusion: { in: CurrencyCatalog::CODES }
  validates :locale, presence: true, inclusion: { in: LOCALES }
  validates :slug, uniqueness: true, allow_nil: true,
                    format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, message: "must contain only lowercase letters, numbers, and hyphens" }

  # Superadmin company search — name / city, plus the admin's name and email.
  scope :search, ->(term) {
    next all if term.blank?

    t = "%#{term.strip}%"
    left_joins(:admin).where(
      "companies.name ILIKE :t OR companies.city ILIKE :t OR " \
      "users.first_name ILIKE :t OR users.last_name ILIKE :t OR users.email ILIKE :t",
      t: t
    ).distinct
  }


  # How this company has configured the engine — a typed CompanySettings, not
  # the raw hash. Read it (`company.settings.feature?(:spaces)`), never
  # `company[:settings]`.
  def settings
    @settings ||= CompanySettings.new(self[:settings])
  end

  # Applies a patch on top of the current settings. Only the keys in the
  # patch change, and anything CompanySettings does not declare is dropped —
  # a client cannot grow the configuration surface by sending extra keys.
  def settings=(patch)
    merged = patch.is_a?(CompanySettings) ? patch : settings.merge(patch)
    @settings = merged
    self[:settings] = merged.to_h
  end

  # A feature being on says the product offers it here. It never says anyone
  # is allowed to use it — that is Role/Permission, checked separately.
  def feature?(key)
    settings.feature?(key)
  end

  def reload(*)
    @settings = nil
    super
  end

  # The short symbol shown next to amounts across the app (e.g. "DT", "€").
  def currency_symbol
    CurrencyCatalog.symbol(currency)
  end

  # How far through first-time setup this company is — derived from its own
  # data, so a step completed anywhere in the app ticks itself off. See
  # Onboarding::State.
  def onboarding_state
    Onboarding::State.for(self)
  end

  # Every company has every feature — the whole product is included. Kept
  # as a method (rather than inlining ModuleCatalog::KEYS everywhere)
  # because the bootstrap payload, serializers and Permissions::Resolve all
  # read "which features does this company have" through here.
  def enabled_module_keys
    [ ModuleCatalog::BASE_KEY ] + ModuleCatalog::KEYS
  end

  # The admin's account subscription: one for every salle they run. Access,
  # plan and invoices are the account's, so locking it locks every salle.
  def subscription
    admin&.subscription
  end

  # Whether this salle's members may sign in to their own app — a Pro
  # account's (or one still on its free trial).
  def member_app?
    subscription&.member_app? || false
  end

  # What the account's plan costs per month, in the currency it is billed
  # in. The same for every salle under one admin: the plan is priced per
  # account, however many salles it covers.
  def monthly_subscription_cents
    subscription&.monthly_cents || SubscriptionPrice.for(currency, plan: SubscriptionPrice::PLANS.first).monthly_cents
  end

  # Platform-wide discount applied to a full year paid up front (info only
  # — billing happens outside the app).
  def annual_discount_percent
    PlatformSetting.current.annual_discount_percent
  end

  # 12 months minus the annual discount, rounded to the cent.
  def annual_subscription_cents
    (monthly_subscription_cents * 12 * (100 - annual_discount_percent) / 100.0).round
  end

  # Opening hours, working days and the brand colour live in `settings` now,
  # not in columns of their own. These readers keep the rest of the app — and
  # the API's shape — exactly as they were.
  def business_hours_start = settings.business_hours_start
  def business_hours_end = settings.business_hours_end
  def working_days = settings.working_days
  def primary_color = settings.primary_color

  # Writers, so every existing caller (and `create(:company, primary_color:)`)
  # keeps working now that the columns are gone.
  def business_hours_start=(value)
    self.settings = { hours: { start: value } }
  end

  def business_hours_end=(value)
    self.settings = { hours: { end: value } }
  end

  def working_days=(value)
    self.settings = { hours: { working_days: value } }
  end

  def primary_color=(value)
    self.settings = { branding: { primary_color: value } }
  end

  # True when the company operates on the given date's weekday.
  def working_day?(date)
    settings.working_day?(date)
  end

  # The schema default, and the answer for a company whose zone cannot be
  # read.
  DEFAULT_TIMEZONE = "Africa/Tunis".freeze

  # The zone "today", "tomorrow at 18:00" and a day's end mean at this gym.
  # Requests and jobs run inside it (Api::V1::BaseController, the cron jobs),
  # so Date.current and Time.zone answer for the gym, not for UTC.
  def time_zone
    Time.find_zone(timezone) || Time.find_zone!(DEFAULT_TIMEZONE)
  end

  private

  SETTINGS_ERRORS = {
    "branding.primary_color" => [ :primary_color, "must be a hex color like #4f46e5" ],
    "hours.working_days" => [ :working_days, "must be a list of distinct weekday numbers (0–6)" ],
    "hours.start" => [ :business_hours_start, "must be a time like 06:00" ],
    "hours.end" => [ :business_hours_end, "must be a time like 22:00" ]
  }.freeze
  private_constant :SETTINGS_ERRORS

  def normalize_settings
    self[:settings] = settings.to_h
  end

  def settings_values_are_usable
    settings.invalid_values.each do |key|
      attribute, message = SETTINGS_ERRORS[key]
      errors.add(attribute || :settings, message || "is not valid")
    end
  end

  def logo_is_an_image
    return unless logo.attached?

    errors.add(:logo, "must be an image (JPEG, PNG, WebP)") unless logo.content_type.in?(ALLOWED_LOGO_TYPES)
  end

  def logo_is_not_too_large
    return unless logo.attached?

    errors.add(:logo, "must be smaller than #{MAX_LOGO_SIZE / 1.megabyte}MB") if logo.blob.byte_size > MAX_LOGO_SIZE
  end

  def timezone_is_known
    return if timezone.blank? || Time.find_zone(timezone)

    errors.add(:timezone, "is not a time zone we know")
  end
end
