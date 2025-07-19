# frozen_string_literal: true

require 'concurrent'
require 'net/http'
require 'uri'
require 'json'
require 'thread'

class PaymentProcessorHealthChecker
  def initialize
    @health = {
      default: { failing: true, minResponseTime: 9999, last_checked_at: nil },
      fallback: { failing: true, minResponseTime: 9999, last_checked_at: nil }
    }
    @health_mutex = Mutex.new

    # Healthchecks URLs
    @health_check_default_url = URI('http://payment-processor-default:8080/payments/service-health')
    @health_check_fallback_url = URI('http://payment-processor-fallback:8080/payments/service-health')

    # Creates a TimerTask for each processor
    # execution_interval: frequency each 5 secs
    # run_now: runs immediatelly when executed
    # timeout_interval: timeout for the task itself, prevents deadlock
    @default_health_checker = Concurrent::TimerTask.new(
      execution_interval: 5,
      run_now: true,
      timeout_interval: 3
    ) do
      check_processor_health(:default, @health_check_default_url)
    end

    @fallback_health_checker = Concurrent::TimerTask.new(
      execution_interval: 5,
      run_now: true,
      timeout_interval: 3
    ) do
      check_processor_health(:fallback, @health_check_fallback_url)
    end
  end

  def start
    @default_health_checker.execute

    Thread.new { @fallback_health_checker.execute }
    p '[PaymentProcessorHealthChecker] Starting...'
  end

  def stop
    @default_health_checker.shutdown
    @fallback_health_checker.shutdown
    p '[PaymentProcessorHealthChecker] Stopped.'
  end

  def get_health(processor_name)
    @health_mutex.synchronize { @health[processor_name].dup }
  end

  private

  def check_processor_health(processor_name, url)
    http = Net::HTTP.new(url.host, url.port)
    http.read_timeout = 2
    http.open_timeout = 1

    request = Net::HTTP::Get.new(health_url.path)

    begin
      response = http.request(request)

      status_update = nil

      if response.is_a?(Net:HTTPSuccess)
        data = JSON.parse(response.body, symbolize_names: true)
        status_update = {
          failing: data[:failing],
          minResponseTime: data[:minResponseTime],
          last_checked_at: Time.now
        }
        p "[PaymentProcessorHealthChecker][#{processor_name}]: #{data[:failing] ? 'FAILING' : 'HEALTHY'} (minResponseTime: #{data[:minResponseTime]})"
      elsif response.code == '429' # Exceeded calls
        warn "[PaymentProcessorHealthChecker][#{processor_name}] Returned 429. Respect the limit..."
      else
        warn "[PaymentProcessorHealthChecker][#{processor_name}] failed with status #{response.code}."
        status_update = { failing: true, last_checked_at: Time.now } # Considerar falhando
      end

      @health_mutex.synchronize do
        @health[processor_name].merge!(status_update) if status_update
      end
    rescue Net::ReadTimeout, Net::OpenTimeout => e
      warn "[PaymentProcessorHealthChecker][#{processor_name}] Timed out: #{e.message}"
      @health_mutex.synchronize do
        @health[processor_name][:failing] = true
        @health[processor_name][:last_checked_at] = Time.now
      end
    rescue StandardError => e
      warn "[PaymentProcessorHealthChecker][#{processor_name}] Unexpected error: #{e.message}"
      @health_mutex.synchronize do
        @health[processor_name][:failing] = true
        @health[processor_name][:last_checked_at] = Time.now
      end
    end
  end
end
