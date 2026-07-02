require 'thread'

class RateLimit
  # Every Nth allow? call also drops empty keys, so IPs that stop posting
  # don't accumulate in @hits forever.
  SWEEP_EVERY = 100

  def initialize(limit:, window:)
    @limit = limit
    @window = window
    @hits = Hash.new { |h, k| h[k] = [] }
    @mutex = Mutex.new
    @calls = 0
  end

  def allow?(key)
    now = Time.now.to_i
    @mutex.synchronize do
      prune(now - @window) if (@calls += 1) % SWEEP_EVERY == 0
      @hits[key].reject! { |t| t < now - @window }
      if @hits[key].size >= @limit
        false
      else
        @hits[key] << now
        true
      end
    end
  end

  def sweep!
    @mutex.synchronize { prune(Time.now.to_i - @window) }
  end

  private

  # Caller must hold @mutex.
  def prune(cutoff)
    @hits.each_value { |arr| arr.reject! { |t| t < cutoff } }
    @hits.delete_if { |_, arr| arr.empty? }
  end
end
