# frozen_string_literal: true

require 'rack'
require 'json'

# This shiny red demon orchestrate and
# unleashes payments data for multiple processors
class FirebrandApp
  def initialize; end

  def call(env)
    req = Rack::Request.new(env)

    routing(req)
  rescue StandardError => e
    internal_error(e)
  end

  private

  def routing(request)
    method = request.request_method
    path = request.path_info

    case [method, path]
    in ['GET', '/health']
      health_check
    else
      not_found
    end
  end

  def not_found
    json_response({ error: 'Not Found' }, 404)
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

  def health_check
    server_info = {
      firebrand_status: 'healthy',
      timestamp: Time.now,
      ruby_version: RUBY_VERSION
    }
    json_response(server_info, 200)
  end

  def json_response(data, status = 200)
    [
      status,
      headers_json,
      [data.to_json]
    ]
  end

  def headers_json
    {
      'Content-Type' => 'application/json',
      'Access-Control-Allow-Origin' => '*',
      'Access-Control-Allow-Methods' => 'GET'
    }
  end
end
