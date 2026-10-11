require 'sinatra/base'
require './asxpio.rb'

# The public bingo site moved to its own repo/container (datacenterbingo);
# only its admin (/admin/bingo) is still served here.
run AsxpioWeb.new
