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
RUN bundle install --without development:test

COPY --chown=asxpio . .

ENV PUMA_PORT=3000
ENV PUMA_THREADS="4:16"
ENV RACK_ENV=production
EXPOSE 3000

CMD ["sh", "-c", "exec puma -b tcp://0.0.0.0:${PUMA_PORT} -t ${PUMA_THREADS} --preload"]
