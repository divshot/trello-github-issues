require 'bundler'
Bundler.require :default, (ENV['RACK_ENV'] || 'development').to_sym
require 'dotenv'
Dotenv.load

require './environment'
require './app'

use Rack::Session::Cookie, secret: ENV['SESSION_SECRET'] || '9e11c6b0b76d24e798a96dc46194b86850a1b3dc'
use OmniAuth::Builder do
  provider :trello, ENV['TRELLO_KEY'], ENV['TRELLO_SECRET'], app_name: 'Trello + GitHub Issues', scope: 'read,write', expiration: 'never'
end

run App