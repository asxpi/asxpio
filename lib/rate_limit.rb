require 'thread'

class RateLimit
  def initialize(limit:, window:)
    @limit = limit
    @window = window
    @hits = Hash.new { |h, k| h[k] = [] }
    @mutex = Mutex.new
  end

  def allow?(key)
    now = Time.now.to_i
    @mutex.synchronize do
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
    cutoff = Time.now.to_i - @window
    @mutex.synchronize do
      @hits.each_value { |arr| arr.reject! { |t| t < cutoff } }
      @hits.delete_if { |_, arr| arr.empty? }
    end
  end
end
