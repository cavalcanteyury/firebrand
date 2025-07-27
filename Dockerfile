FROM ruby:3.4 AS base

# Defines o working directory for the container
WORKDIR /app

# Instll container deps
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential libpq-dev && \
    rm -rf /var/lib/apt/lists/*

# Copies Gemfile and Gemfile.lock to container and bundle installs it
COPY Gemfile Gemfile.lock ./
RUN bundle install

# Copies remaining files
COPY . .

# Exposing 9999 PORT that RACK should listen
EXPOSE 3000

CMD ["bundle", "exec", "puma", "-b", "tcp://0.0.0.0:3000"]
