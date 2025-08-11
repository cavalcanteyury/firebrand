# frozen_string_literal: true

require 'redis'

require_relative 'redis_pool'

class RedisStorage
  def initialize; end

  def save(correlation_id:, processor_used:, amount:, requested_at: Time.now.utc.iso8601)
    payment_data = {
      correlationId: correlation_id,
      amount: amount,
      processor: processor_used,
      requestedAt: Time.now.utc.iso8601
    }

    RedisPool.with do |redis|
      timestamp_score = Time.parse(requested_at.to_s).to_f

      redis.multi do
        redis.set("processed:#{correlation_id}", 1, ex: 3600)
        redis.zadd('payments_log', timestamp_score, payment_data.to_json)
        redis.incr("totalRequests:#{processor_used}")
        redis.incrbyfloat("totalAmount:#{processor_used}", amount)
      end
    end
  end

  def payments_summary(from_time, to_time)
    return summary_from_counters if from_time.nil? && to_time.nil?

    process_summary(from_time, to_time)
  end

  def summary_from_counters
    RedisPool.with do |redis|
      %w[default fallback].each_with_object({}) do |type, hash|
        hash[type] = {
          totalRequests: redis.get("totalRequests:#{type}").to_i,
          totalAmount: '%.2f' % redis.get("totalAmount:#{type}").to_f
        }
      end
    end
  end

  def process_summary(from_time, to_time)
    summary = {
      default: { totalRequests: 0, totalAmount: 0.0 },
      fallback: { totalRequests: 0, totalAmount: 0.0 }
    }

    from_score = from_time ? Time.parse(from_time).to_f : '-inf'
    to_score = to_time ? Time.parse(to_time).to_f : '+inf'

    RedisPool.with do |redis|
      payments = redis.zrangebyscore('payments_log', from_score, to_score)

      payments.each do |json|
        payment = JSON.parse(json)
        processor = payment['processor'].to_sym
        amount = payment['amount'].to_f

        if summary[processor]
          summary[processor][:totalRequests] += 1
          summary[processor][:totalAmount] += amount
        end
      end
    end

    {
      default: {
        totalRequests: summary[:default][:totalRequests],
        totalAmount: '%.2f' % summary[:default][:totalAmount]
      },
      fallback: {
        totalRequests: summary[:fallback][:totalRequests],
        totalAmount: '%.2f' % summary[:fallback][:totalAmount]
      }
    }
  end
end
