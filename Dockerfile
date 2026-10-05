# syntax=docker/dockerfile:1
# Production image for the Fitora API. Also bakes the Angular SPA into
# public/ so one container serves both the API and the web app on one origin.
# Build from the repo root:  docker build -f backend/Dockerfile -t fitora .

# ── 1. Build the Angular SPA ────────────────────────────────────────────
FROM node:20-slim AS spa
WORKDIR /spa
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/ ./
RUN npx ng build --configuration production
# → /spa/dist/frontend/browser

# ── 2. Ruby base ───────────────────────────────────────────────────────
FROM registry.docker.com/library/ruby:3.4.7-slim AS base
WORKDIR /rails
ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test
RUN apt-get update -qq \
 && apt-get install --no-install-recommends -y curl libjemalloc2 libvips postgresql-client \
 && rm -rf /var/lib/apt/lists /var/cache/apt/archives

# ── 3. Build gems ──────────────────────────────────────────────────────
FROM base AS build
RUN apt-get update -qq \
 && apt-get install --no-install-recommends -y build-essential git libpq-dev pkg-config \
 && rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY backend/Gemfile backend/Gemfile.lock ./
RUN bundle install \
 && rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git \
 && bundle exec bootsnap precompile --gemfile

COPY backend/ ./
RUN bundle exec bootsnap precompile app/ lib/

# ── 4. Final image ─────────────────────────────────────────────────────
FROM base
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails
COPY --from=spa   /spa/dist/frontend/browser /rails/public

# Run as an unprivileged user.
RUN groupadd --system --gid 1000 rails \
 && useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash \
 && chown -R rails:rails db log storage tmp
USER 1000:1000

ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 3000
CMD ["./bin/rails", "server"]
