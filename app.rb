# frozen_string_literal: true

require 'rack'
require 'json'
require 'time'
require 'rack/request'
require 'redis'
require 'sequel'

# This shiny red demon orchestrate and
# unleashes payments data for multiple processors
class FirebrandApp
  def initialize
    # Redis config
    @redis = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
    @payment_queue_key = 'payments:priority_queue'

    # PostgreSQL config
    db_url = ENV.fetch('DATABASE_URL', 'postgres://rinha:rinha2025@postgres:5432/rinha_db')
    @db = Sequel.connect(db_url)
    @payments_table = @db[:payments]
  rescue Sequel::DatabaseConnectionError => e
    puts "[DatabaseError] Error connecting to database: #{e.message}"
    raise
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

  def handle_payments_summary(request)
    from_param = request.params['from']
    to_param = request.params['to']

    begin
      from_time = from_param ? Time.parse(from_param).utc : nil
      to_time = to_param ? Time.parse(to_param).utc : nil
    rescue ArgumentError
      return json_response({error: 'Invalid date format for params'}, 400)
    end

    where_clause_parts = []
    sql_parameters = {}

    if from_time && to_time
      where_clause_parts << 'processed_at BETWEEN :from_time AND :to_time'
      sql_parameters[:from_time] = from_time
      sql_parameters[:to_time] = to_time
    elsif from_time
      where_clause_parts << 'processed_at >= :from_time'
      sql_parameters[:from_time] = from_time
    elsif to_time
      where_clause_parts << 'processed_at <= :to_time'
      sql_parameters[:to_time] = to_time
    end

    where_sql = where_clause_parts.empty? ? '' : "WHERE #{where_clause_parts.join(' AND ')}"

    sql_query = <<~SQL
      SELECT
          processor_type,
          COUNT(correlation_id) AS total_requests,
          SUM(amount) AS total_amount
      FROM
          payments
      #{where_sql}
      GROUP BY
          processor_type;
    SQL

    results = @db.fetch(sql_query, sql_parameters).all

    default_summary = { totalRequests: 0, totalAmount: BigDecimal('0.00') }
    fallback_summary = { totalRequests: 0, totalAmount: BigDecimal('0.00') }

    results.each do |row|
      processor_type = row[:processor_type]
      requests = row[:total_requests]
      amount = row[:total_amount]

      if processor_type == 'default'
        default_summary[:totalRequests] = requests
        default_summary[:totalAmount] = amount
      elsif processor_type == 'fallback'
        fallback_summary[:totalRequests] = requests
        fallback_summary[:totalAmount] = amount
      end
    end

    response_body = {
      default: {
        totalRequests: default_summary[:totalRequest],
        totalAmount: '%.2f' % default_summary[:totalAmount]
      },
      fallback: {
        totalRequests: fallback_summary[:totalRequest],
        totalAmount: '%.2f' % fallback_summary[:totalAmount]
      }
    }

    json_response(response_body, 200)
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
