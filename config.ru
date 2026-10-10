require 'sinatra/base'
require './asxpio.rb'
require './bingo_web.rb'

# One process, two sites: BINGO_HOST gets the bingo, everything else asxp.io.
asxpio     = AsxpioWeb.new
bingo      = BingoWeb.new
bingo_host = ENV['BINGO_HOST']

run lambda { |env|
  host = Rack::Request.new(env).host
  (bingo_host && host == bingo_host ? bingo : asxpio).call(env)
}
