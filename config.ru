# frozen_string_literal: true

require_relative 'app'

# Logs
use Rack::CommonLogger

# CORS Middleware
use Rack::Deflater

run FirebrandApp.new
