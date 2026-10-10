require "rails_helper"

# The sweep: every route the app answers, asked without a token.
#
# The other files in this directory each test a rule someone thought of. This
# one tests the rule nobody has to remember: a controller added next month is
# covered the day its route is drawn, because the list comes from the router
# rather than from a spec someone maintains.
#
# A route that is genuinely public must be named in PUBLIC below. Adding a
# name is a deliberate act with a reason next to it; forgetting to add one is
# a failing build, which is the right way round.
RSpec.describe "Every route is closed by default", type: :request do
  # The unauthenticated surface, in full. Everything here either creates a
  # session or is reached from a link in an email, where the token in the URL
  # is the credential.
  PUBLIC = [
    %r{\A/api/v1/auth/(login|register)\z},
    %r{\A/api/v1/password_resets},
    %r{\A/api/v1/email_verifications},
    # A member accepting their gym's invitation — the emailed token is the
    # credential, and they have no password until this sets one.
    %r{\A/api/v1/invitations},
    # Version check — the client asks before it has a session, to tell
    # someone their app is out of date.
    %r{\A/api/v1/app_version\z},
    # The mobile app becoming one salle's app before anyone signs in: the
    # salle's member code or coach key in the URL is the credential (long,
    # random, regeneratable, throttled — Api::V1::TenantsController).
    %r{\A/api/v1/tenants/[^/]+/app_config\z},
    # Health check and the SPA's own HTML.
    %r{\A/up\z}
  ].freeze

  # Not part of the API surface: Sidekiq's dashboard has its own HTTP basic
  # auth, and the SPA catch-all serves index.html by design.
  IGNORED = [ %r{\A/sidekiq}, /\*path/ ].freeze

  # Every concrete (verb, path) the router will answer, with an id in place
  # of each dynamic segment. The id is a well-formed UUID that matches
  # nothing: authentication runs before any lookup, so the answer must be 401
  # regardless — if it is 404, something looked the record up first.
  def self.api_routes
    Rails.application.routes.routes.filter_map do |route|
      spec = route.path.spec.to_s.sub(/\(\.:format\)\z/, "")
      next if IGNORED.any? { |re| spec.match?(re) }
      next unless spec.start_with?("/api/", "/up")

      verb = route.verb.to_s.presence || "GET"
      next if PUBLIC.any? { |re| spec.match?(re) }

      path = spec.gsub(/:[a-z_]+/, "00000000-0000-4000-8000-000000000000")
      [ verb.downcase.to_sym, path ]
    end.uniq
  end

  ROUTES = api_routes.freeze

  it "finds the routes to sweep at all" do
    # A refactor that breaks the enumeration would otherwise turn this whole
    # file into a silent pass.
    expect(ROUTES.size).to be > 60
    expect(ROUTES).to include([ :get, "/api/v1/clients" ])
  end

  ROUTES.each do |verb, path|
    it "#{verb.to_s.upcase} #{path} refuses an anonymous caller" do
      public_send(verb, path, headers: { "CONTENT_TYPE" => "application/json" })

      expect(response).to have_http_status(:unauthorized),
        "#{verb.to_s.upcase} #{path} answered #{response.status} without a token. " \
        "Either it inherits from Api::V1::BaseController, or it belongs in PUBLIC with a reason."
    end
  end
end

# The other sweep: a gym whose access is closed.
#
# The lock lives in one before_action on Api::V1::BaseController, which is
# exactly the kind of thing a new controller can opt out of by accident (a
# stray `skip_before_action`, or not inheriting from the base at all). Rather
# than trust that, ask every operational endpoint.
RSpec.describe "A locked gym answers nothing operational", type: :request do
  let(:admin) { create(:user, :admin) }
  let!(:company) { create(:company, admin: admin) }
  # Full permissions on purpose: the only thing that may refuse these is the
  # lock, so a 403 here would mean the lock never got a chance to speak.
  let(:staff) do
    seat = create(:staff_member, company: company, role: :moderator)
    seat.assigned_role.update!(permissions: Permission::ALL)
    seat.user
  end

  before do
    create(:subscription, :closed, company: company)
    create(:invoice, :lapsed, company: company)
  end

  # Reads only: a sweep that POSTs would be testing the lock and the write
  # path at once, and the lock is what is on trial here.
  #
  # `/superadmin` is the platform operator, not this tenant. `/me` is a member's
  # own login, which the lock deliberately leaves alone — their gym's bill is
  # not their problem to see. `/bootstrap` skips it on purpose, so the client
  # can render the "access closed" screen at all, and `/auth/me` is on
  # AuthController rather than the base for the same reason: someone locked
  # out still has to be able to see who they are signed in as, and sign out.
  LOCKED_EXEMPT = %r{\A/api/v1/(superadmin|me)/|\A/api/v1/(bootstrap|app_version|auth/me)\z|\A/api/v1/tenants/[^/]+/app_config\z}

  LOCKED_ROUTES = ROUTES.select { |verb, path| verb == :get && !path.match?(LOCKED_EXEMPT) }.freeze

  it "has operational endpoints to sweep" do
    expect(LOCKED_ROUTES.size).to be > 20
  end

  LOCKED_ROUTES.each do |_verb, path|
    it "GET #{path} answers 402, whatever the caller is allowed to do" do
      get path, headers: auth_headers(staff)

      expect(response).to have_http_status(:payment_required),
        "GET #{path} answered #{response.status} for a locked gym's staff. " \
        "The lock is one before_action on Api::V1::BaseController; this endpoint got past it."
    end
  end
end
