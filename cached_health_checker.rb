# frozen_string_literal: true

require 'concurrent'
require 'net/http'
require 'uri'
require 'json'
require 'thread'

class CachedHealthChecker
  HEALTH_CACHE_KEY = 'health_checker:status'

  def initialize(redis)
    @redis = redis
  end

  def start; end

  def stop; end

  def get_health(processor_name)
    cached_health = @redis.hget(HEALTH_CACHE_KEY, processor_name.to_s)

    if cached_health
      JSON.parse(cached_health, symbolize_names: true)
    else
      { failing: true, minResponseTime: 9999, last_checked_at: nil }
    end
  end

  def choose_best_processor
    default_health = get_health(:default)
    fallback_health = get_health(:fallback)

    return :default unless default_health[:failing]
    return :fallback unless fallback_health[:failing]
    :default
  end
end
