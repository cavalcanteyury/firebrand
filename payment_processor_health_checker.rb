# frozen_string_literal: true

require 'concurrent'
require 'net/http'
require 'uri'
require 'json'
require 'thread'

class PaymentProcessorHealthChecker
  HEALTH_CACHE_KEY = 'health_checker:status'

  # all seconds
  HEALTH_CHECK_INTERVAL = 5
  HTTP_TIMEOUT = 2

  def initialize(redis)
    @redis = redis
    @health = {
      default: { failing: true, minResponseTime: 9999, last_checked_at: nil },
      fallback: { failing: true, minResponseTime: 9999, last_checked_at: nil }
    }
    @health_mutex = Mutex.new

    @processor_urls = {
      default: URI('http://payment-processor-default:8080/payments/service-health'),
      fallback: URI('http://payment-processor-fallback:8080/payments/service-health')
    }

    # Creates a TimerTask for each processor
    setup_health_checkers
  end

  def start
    @default_health_checker.execute

    Thread.new do
      sleep 0.2
      @fallback_health_checker.execute
    end

    p '[HealthChecker] Starting...'
  end

  def stop
    @default_health_checker.shutdown
    @fallback_health_checker.shutdown
    p '[HealthChecker] Stopped.'
  end

  def processors_health
    @health_mutex.synchronize { @health.dup }
  end

  def choose_best_processor
    health_data = processors_health

    default_health = health_data[:default]
    fallback_health = health_data[:fallback]

    # if both unhealthy, choose less consecutive failures
    if default_health[:failing] && fallback_health[:failing]
      if default_health[:consecutive_failures] <= fallback_health[:consecutive_failures]
        return :default
      else
        return :fallback
      end
    end

    # if default is the only one healthy, use it
    return :default if !default_health[:failing] && fallback_health[:failing]

    # if fallback is the only one healthy, use it
    return :fallback if default_health[:failing] && !fallback_health[:failing]

    # if both is healthy, then we consider the minResponseTime, to know if we can
    # choose default instead of fallback
    if !default_health[:failing] && !fallback_health[:failing]
      if default_health[:minResponseTime] > 1000 && 
         fallback_health[:minResponseTime] < default_health[:minResponseTime] * 0.5
        return :fallback
      else
        return :default
      end
    end

    # Default is the... default lol
    :default
  end

  private

  def setup_health_checkers
    @default_health_checker = Concurrent::TimerTask.new(
      execution_interval: HEALTH_CHECK_INTERVAL,
      run_now: true
    ) do
      check_processor_health(:default)
    end

    @fallback_health_checker = Concurrent::TimerTask.new(
      execution_interval: HEALTH_CHECK_INTERVAL,
      run_now: true
    ) do
      check_processor_health(:fallback)
    end
  end

  def check_processor_health(processor_name)
    url = @processor_urls[processor_name]
    http = Net::HTTP.new(url.host, url.port)

    http.read_timeout = HTTP_TIMEOUT
    http.open_timeout = 1

    request = Net::HTTP::Get.new(url.path)

    begin
      response = http.request(request)
      process_health_response(processor_name, response)
    rescue Net::ReadTimeout, Net::OpenTimeout => e
      handle_health_check_error(processor_name, "Timeout: #{e.message}")
    rescue StandardError => e
      handle_health_check_error(processor_name, "Unexpected error: #{e.message}")
    end
  end

  def process_health_response(processor_name, response)
    case response
    in Net::HTTPSuccess
      data = JSON.parse(response.body, symbolize_names: true)
      update_health_status(processor_name, {
        failing: data[:failing],
        minResponseTime: data[:minResponseTime],
        last_checked_at: Time.now,
        consecutive_failures: data[:failing] ? @health[processor_name][:consecutive_failures] + 1 : 0
      })

      status = data[:failing] ? 'FAILING' : 'HEALTHY'
      p "[HealthChecker][#{processor_name}]: #{status} (minResponseTime: #{data[:minResponseTime]}ms)"
    in Net::HTTPTooManyRequests # 429
      p "[HealthChecker][#{processor_name}] Rate limited (429). Respecting limit..."
    else
      p "[HealthChecker][#{processor_name}] HTTP #{response.code}: #{response.message}"
      mark_as_failing(processor_name)
    end
  end

  def handle_health_check_error(processor_name, error_message)
    puts "[HealthChecker][#{processor_name}] #{error_message}"
    mark_as_failing(processor_name)
  end

  def update_health_status(processor_name, status_update)
    @health_mutex.synchronize do
      @health[processor_name].merge!(status_update)

      if @redis
        @redis.hset(HEALTH_CACHE_KEY, processor_name.to_s, @health[processor_name].to_json)
        @redis.expire(HEALTH_CACHE_KEY, 30)
      end
    end
  end

  def mark_as_failing(processor_name)
    failing_data = {
      failing: true,
      last_checked_at: Time.now,
      consecutive_failures: @health[processor_name][:consecutive_failures] += 1
    }

    @health_mutex.synchronize do
      @health[processor_name].merge!(failing_data)
    end
  end
end
