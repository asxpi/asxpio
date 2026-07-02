require_relative 'test_helper'

class RateLimitTest < Minitest::Test
  def test_allows_up_to_limit_then_denies
    rl = RateLimit.new(limit: 5, window: 3600)
    assert (1..5).all? { rl.allow?('1.2.3.4') }
    refute rl.allow?('1.2.3.4')
  end

  def test_keys_are_independent
    rl = RateLimit.new(limit: 1, window: 3600)
    assert rl.allow?('a')
    refute rl.allow?('a')
    assert rl.allow?('b')
  end

  def test_sweep_removes_stale_keys
    rl = RateLimit.new(limit: 5, window: 3600)
    hits = rl.instance_variable_get(:@hits)
    old = Time.now.to_i - 7200
    50.times { |i| hits["stale-#{i}"] << old }
    rl.sweep!
    assert_empty hits.keys.grep(/\Astale-/)
  end

  def test_allow_prunes_opportunistically
    rl = RateLimit.new(limit: 5, window: 3600)
    hits = rl.instance_variable_get(:@hits)
    old = Time.now.to_i - 7200
    50.times { |i| hits["stale-#{i}"] << old }
    RateLimit::SWEEP_EVERY.times { rl.allow?('fresh') }
    assert_empty hits.keys.grep(/\Astale-/)
    assert hits.key?('fresh')
  end
end
