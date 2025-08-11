# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'concurrent-ruby'

require_relative 'lib/redis_pool'
require_relative 'lib/redis_storage'

class PaymentWorker
  PAYMENT_QUEUE_KEY = 'payments:priority_queue'
  MAX_RETRIES = 3
  THREAD_POOL_SIZE = ENV.fetch('THREAD_POOL_SIZE', 10)

  def initialize
    @processors = {
      default: {
        url: URI('http://payment-processor-default:8080/payments'),
        timeout: 0.8
      },
      fallback: {
        url: URI('http://payment-processor-fallback:8080/payments'),
        timeout: 0.2
      }
    }
    @running = false
    @storage = RedisStorage.new
    @worker_thread = nil
    @thread_pool = Concurrent::FixedThreadPool.new(THREAD_POOL_SIZE)
  end

  def start
    return if @running

    @running = true
    puts '[PaymentWorker] Starting payment processing...'

    @worker_thread = Thread.new do
      feed_thread_pool_loop
    end
  end

  def stop
    return unless @running

    puts '[PaymentWorker] Stopping...'
    @running = false
    @worker_thread&.join(10)
    @thread_pool.shutdown
    @thread_pool.wait_for_termination(10)
    puts '[PaymentWorker] Stopped.'
  end

  private

  def feed_thread_pool_loop
    while @running
      begin
        RedisPool.with do |redis|
          payment_data = redis.lpop(PAYMENT_QUEUE_KEY)

          if payment_data.nil? || payment_data.empty?
            sleep 0.002
            next
          end

          payment = JSON.parse(payment_data, symbolize_names: true)

          @thread_pool.post do
            process_payment(payment)
          rescue StandardError => e
            puts "[PaymentWorker][ThreadPool Error] Failed to process payment in thread: #{e.message}"
            puts e.backtrace.join("\n")
          end
        end
      rescue StandardError => e
        puts "[PaymentWorker][FeedLoop Error] Error in loop: #{e.message}"
        puts e.backtrace.join("\n")
        sleep 1
      end
    end
  end

  def process_payment(payment)
    MAX_RETRIES.times do |try|
      return if send_to_processor(payment, :default)

      sleep(0.003 * (try + 1)) if try < 2
    end

    return if send_to_processor(payment, :fallback)

    puts '💀 Both processors failed 💀'
  end

  def send_to_processor(payment, processor)
    url = @processors[processor][:url]
    timeout = @processors[processor][:timeout]

    Net::HTTP.start(url.host, url.port) do |http|
      http.open_timeout = timeout
      http.read_timeout = timeout

      request = Net::HTTP::Post.new(url.path, 'Content-Type' => 'application/json')
      request.body = payment.to_json
      response = http.request(request)

      if response.is_a?(Net::HTTPSuccess)
        save_to_storage(payment, processor)
        puts "[PaymentWorker] ✅ Payment #{payment[:correlationId]} processed via #{processor}: HTTP #{response.code}"
        true
      else
        puts "[PaymentWorker] ❌ Failed to process payment #{payment[:correlationId]} via #{processor}: HTTP #{response.code}"
        false
      end
    end
  rescue Net::ReadTimeout, Net::OpenTimeout => e
    puts "[PaymentWorker] Timeout on #{processor}: #{e.message}"
    false
  rescue StandardError => e
    puts "[PaymentWorker] Error on #{processor}: #{e.message}"
    false
  end

  def save_to_storage(payment, processor_used)
    @storage.save(
      correlation_id: payment[:correlationId],
      processor_used: processor_used.to_s,
      amount: payment[:amount],
      requested_at: payment[:requestedAt]
    )
  end
end
