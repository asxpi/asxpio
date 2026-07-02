FROM ruby:3.4-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
 && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 11000 asxpio \
 && useradd -d /app -u 21000 -g 11000 -m -s /bin/bash asxpio

WORKDIR /app
USER asxpio

ENV GEM_HOME=/app/bundle
ENV PATH="${GEM_HOME}/bin:${PATH}"

COPY --chown=asxpio Gemfile Gemfile.lock* ./
ENV BUNDLE_FROZEN=true
RUN bundle install --without development:test

COPY --chown=asxpio . .

ENV PUMA_PORT=3000
ENV PUMA_THREADS="4:16"
ENV RACK_ENV=production
EXPOSE 3000

# Slim image has no curl; ruby is right there.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ruby -rnet/http -e 'port = ENV.fetch("PUMA_PORT", "3000"); exit(Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/healthz")).code == "200" ? 0 : 1)'

CMD ["sh", "-c", "exec puma -b tcp://0.0.0.0:${PUMA_PORT} -t ${PUMA_THREADS} --preload"]
