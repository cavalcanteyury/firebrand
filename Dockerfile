FROM ruby:3.4.4-slim-bullseye

# Defines o working directory for the container
WORKDIR /app

# Instll container deps
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

# Copies Gemfile and Gemfile.lock to container and bundle installs it
COPY Gemfile Gemfile.lock ./
RUN bundle install

# Copies remaining files
COPY . .

# Exposing 9999 PORT that RACK should listen
EXPOSE 9999

CMD ["bundle", "exec", "puma", "-b", "tcp://0.0.0.0:9999"]
