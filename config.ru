require 'sinatra/base'
require './asxpio.rb'
require './bingo_web.rb'

# One process, two sites: BINGO_HOST gets the bingo, everything else asxp.io.
asxpio     = AsxpioWeb.new
bingo      = BingoWeb.new
bingo_host = ENV['BINGO_HOST']

run lambda { |env|
  req = Rack::Request.new(env)
  if bingo_host && req.host == "www.#{bingo_host}"
    [301, { 'location' => "https://#{bingo_host}#{req.fullpath}" }, []]
  else
    (bingo_host && req.host == bingo_host ? bingo : asxpio).call(env)
  end
}
