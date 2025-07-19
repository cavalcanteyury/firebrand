# frozen_string_literal: true

require 'rack'
require 'json'
require 'time'
require 'rack/request'
require 'redis'

# This shiny red demon orchestrate and
# unleashes payments data for multiple processors
class FirebrandApp
  def initialize
    @redis = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
    @payment_queue_key = 'payments:priority_queue'
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

  def routing(request)
    method = request.request_method
    path = request.path_info

    case [method, path]
    in ['GET', '/health']
      health_check
    in ['POST', '/payments']
      handle_payment(request)
    # in ['GET', '/payments-queue']
    #   handle_payments_queue
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

  def health_check
    server_info = {
      firebrand_status: 'healthy',
      timestamp: Time.now,
      ruby_version: RUBY_VERSION
    }
    json_response(server_info, 200)
  end

  def handle_payment(request)
    body = request.body.read
    payment_data = parse_body(body)

    payment_request = {
      correlationId: payment_data[:correlationId],
      amount: payment_data[:amount].to_f,
      requestedAt: Time.now.utc.iso8601,
      enqueued_at: Time.now.utc.iso8601
    }

    payment_indexed_json = payment_request.to_json
    amount_score = payment_request[:amount]

    @redis.zadd(@payment_queue_key, amount_score, payment_indexed_json)

    json_response({ message: 'Pagamento enfileirado com sucesso para processamento.' }, 201)
  end

  def parse_body(body)
    JSON.parse(body, symbolize_names: true)
  end

  def handle_payments_queue
    json_response({ current_queue: @payment_queue }, 200)
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
