# syntax=docker/dockerfile:1
# check=error=true

# THE STANDALONE SYNC HOST, containerised. Built from THIS repo, which is the whole reason it is
# simpler than the maker app's Dockerfile: the engine is the source here, not a private git: gem, so
# there is no deploy key, no BuildKit secret, and no SSH in the build at all.
#
# WHAT IT DELIBERATELY DOES NOT INSTALL, all of which the maker app's image needs and this one has no
# use for: libvips, pdfium, resvg, f3d, the Rust STL thumbnailer, and Node/asset precompilation. This
# app is `config.api_only` and renders no views -- it holds chunks and serves JSON. Every one of those
# would be megabytes to support a code path that does not exist here.

ARG RUBY_VERSION=3.4.7
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# /rails IS THE REPO, AND THE APP IS /rails/host. The host app's Gemfile is this repository's root
# Gemfile (`gemspec` plus sqlite3 and puma), so the image needs the gem source and the app together --
# splitting them would mean vendoring this gem into its own host.
WORKDIR /rails

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 sqlite3 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development"

FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# THE GEMSPEC IS COPIED WITH THE GEMFILE, and lib/tinkerex_sync/version.rb with it, because the
# Gemfile's `gemspec` line evaluates tinkerex-sync.gemspec at resolve time and that file does
# `require_relative "lib/tinkerex_sync/version"`. Copying only Gemfile+lock -- which is what every
# Rails Dockerfile does -- fails here with a LoadError that names the version file and not the cause.
COPY Gemfile Gemfile.lock tinkerex-sync.gemspec ./
COPY lib/tinkerex_sync/version.rb lib/tinkerex_sync/version.rb
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache

COPY . .

FROM base

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash

COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# STORAGE HOLDS THE DATABASE AND, WITH STORAGE_BACKEND=local, THE CHUNKS THEMSELVES. It must be a
# VOLUME in any real deployment (config/deploy.yml declares one): losing it loses the library, not a
# cache. The chown matters because the app runs as uid 1000 and a volume mounted over this path
# inherits root ownership otherwise.
RUN mkdir -p host/storage host/tmp host/log && chown -R rails:rails host

USER 1000:1000
WORKDIR /rails/host

# db:prepare RUNS HERE, NOT IN CMD, so it happens for the server and NOT for `kamal app exec`.
ENTRYPOINT ["/rails/host/bin/docker-entrypoint"]

EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
