# frozen_string_literal: true

require 'rack'
require 'json'
require 'time'
require 'rack/request'

require_relative 'payment_worker'
require_relative 'lib/redis_pool'
require_relative 'lib/redis_storage'

# This shiny red demon orchestrate and
# unleashes payments data for multiple processors
class FirebrandApp
  PAYMENT_QUEUE_KEY = 'payments:priority_queue'

  def initialize
    @payment_worker = PaymentWorker.new
    @storage = RedisStorage.new

    start
  end

  def call(env)
    req = Rack::Request.new(env)

    routing(req)
  rescue StandardError => e
    puts "INTERNAL ERROR: #{e.message}"
    puts e.backtrace.join("\n")
    internal_error(e)
  end

  private

  def start
    @payment_worker.start

    at_exit do
      @payment_worker.stop
    end
  end

  def routing(request)
    method = request.request_method
    path = request.path_info

    case [method, path]
    in ['POST', '/payments']
      handle_payment(request)
    in ['GET', '/payments-summary']
      handle_payments_summary(request)
    else
      not_found
    end
  end

  def internal_error(error)
    json_response(
      {
        error: 'Internal Server Error',
        message: error.message,
        timestamp: Time.now
      }, 500
    )
  end

  def not_found
    json_response({ error: 'Not Found' }, 404)
  end

  def handle_payment(request)
    body = request.body.read
    payment_data = parse_body(body)

    payment_request = {
      correlationId: payment_data[:correlationId],
      amount: payment_data[:amount].to_f,
      requestedAt: Time.now.utc.iso8601(3),
      enqueued_at: Time.now.utc.iso8601(3)
    }

    RedisPool.with do |redis|
      redis.rpush(PAYMENT_QUEUE_KEY, payment_request.to_json)
    end

    json_response({ message: 'Pagamento enfileirado com sucesso' }, 201)
  end

  def handle_payments_summary(request)
    from_param = request.params['from']
    to_param = request.params['to']

    summary = @storage.payments_summary(from_param, to_param)

    json_response(summary, 200)
  end

  def parse_body(body)
    JSON.parse(body, symbolize_names: true)
  end

  def json_response(data, status = 200)
    body = data.to_json

    [
      status,
      headers_json,
      [body]
    ]
  end

  def headers_json
    {
      'content-type' => 'application/json',
      'access-control-allow-origin' => '*',
      'access-control-allow-methods' => 'get'
    }
  end
end
