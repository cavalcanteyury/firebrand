# frozen_string_literal: true

require 'redis'
require 'connection_pool'
require 'singleton'

class RedisPool
  include Singleton

  def initialize
    @pool = ConnectionPool.new(size: 10) do
      Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
    end
  end

  def self.with(&block)
    instance.with(&block)
  end

  def with(&block)
    @pool.with(&block)
  end
end
