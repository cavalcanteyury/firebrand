# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

class PaymentWorker
  PAYMENT_QUEUE_KEY = 'payments:priority_queue'

  def initialize(redis:, database:, health_checker:)
    @redis = redis
    @db = database
    @payments_table = @db[:payments]
    @health_checker = health_checker

    @processor_urls = {
      default: URI('http://payment-processor-default:8080/payments'),
      fallback: URI('http://payment-processor-fallback:8080/payments')
    }

    @running = false
    @worker_thread = nil
  end

  def start
    return if @running

    @running = true
    puts '[PaymentWorker] Starting payment processing...'

    @worker_thread = Thread.new do
      process_payments_loop
    end
  end

  def stop
    return unless @running

    puts '[PaymentWorker] Stopping...'
    @running = false
    @worker_thread&.join(5)
    puts '[PaymentWorker] Stopped.'
  end

  private

  def process_payments_loop
    while @running
      begin
        payment_data, _amount = @redis.zpopmax(PAYMENT_QUEUE_KEY, 1)

        if payment_data.nil? || payment_data.empty?
          sleep 0.2
          next
        end

        payment_json = payment_data
        payment = JSON.parse(payment_json, symbolize_names: true)

        process_payment(payment)
      rescue StandardError => e
        # puts "[PaymentWorker] Error in loop: #{e.message}"
        puts e
        sleep 0.1
      end
    end
  end

  def process_payment(payment)
    puts "[PaymentWorker] Processing #{payment[:correlationId]} (#{payment[:amount]})"

    chosen_processor = @health_checker.choose_best_processor
    success = send_to_processor(payment, chosen_processor)

    unless success
      other_processor = chosen_processor == :default ? :fallback : :default
      puts "[PaymentWorker] Retrying with #{other_processor} processor"
      success = send_to_processor(payment, other_processor)
      chosen_processor = other_processor if success
    end

    if success
      save_to_database(payment, chosen_processor)
      puts "[PaymentWorker] ✅ Payment #{payment[:correlationId]} processed via #{chosen_processor}"
    else
      puts "[PaymentWorker] ❌ Failed to process payment #{payment[:correlationId]}"
      # Aqui você pode recolocar na fila ou logar para análise posterior
    end
  end

  def send_to_processor(payment, processor)
    url = @processor_urls[processor]

    http = Net::HTTP.new(url.host, url.port)
    http.read_timeout = 10
    http.open_timeout = 5

    request = Net::HTTP::Post.new(url.path)
    request['Content-Type'] = 'application/json'

    body = {
      correlationId: payment[:correlationId],
      amount: payment[:amount],
      requestedAt: payment[:requestedAt]
    }.to_json

    request.body = body
    response = http.request(request)

    if response.is_a?(Net::HTTPSuccess)
      puts "[PaymentWorker] Sent to #{processor}: HTTP #{response.code}"
      true
    else
      puts "[PaymentWorker] Failed on #{processor}: HTTP #{response.code}"
      false
    end
  rescue Net::ReadTimeout, Net::OpenTimeout => e
    puts "[PaymentWorker] Timeout on #{processor}: #{e.message}"
    false
  rescue StandardError => e
    puts "[PaymentWorker] Error on #{processor}: #{e.message}"
    false
  end

  def save_to_database(payment, processor_used)
    @payments_table.insert(
      correlation_id: payment[:correlationId],
      amount: payment[:amount],
      requested_at: payment[:requestedAt],
      processor_type: processor_used.to_s,
      processed_at: Time.now.utc
    )
  rescue StandardError => e
    puts "[PaymentWorker] Database error: #{e.message}"
  end
end
