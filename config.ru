require 'sinatra/base'
require './asxpio.rb'
require './bingo_web.rb'

# One process, two sites: the bingo hosts get BingoWeb, everything else
# asxp.io. BINGO_HOST is canonical (www. redirects to it); BINGO_ALT_HOST
# serves the same card, e.g. while the canonical domain's DNS settles.
asxpio      = AsxpioWeb.new
bingo       = BingoWeb.new
bingo_host  = ENV['BINGO_HOST']
bingo_hosts = BingoWeb::HOSTS

run lambda { |env|
  req = Rack::Request.new(env)
  if bingo_host && req.host == "www.#{bingo_host}"
    [301, { 'location' => "https://#{bingo_host}#{req.fullpath}" }, []]
  else
    (bingo_hosts.include?(req.host) ? bingo : asxpio).call(env)
  end
}
