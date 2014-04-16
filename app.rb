require 'sinatra'
require 'securerandom'

class App < Sinatra::Base
  class Hook < Hashie::Mash
    def initialize(attributes = {}, default = nil)
      super
      self.id ||= SecureRandom.hex(20)
    end
    
    def self.create(attributes)
      new(attributes).save
    end
    
    def self.all(*ids)
      keys = ids.map{|id| "hook:#{id}"}
      $redis.mget(*keys).compact.map{|data| new(JSON.parse(data)) }
    end
    
    def self.find(id)
      all(id).first
    end
    
    def save
      $redis.set "hook:#{id}", to_json
      self
    end
  end
  
  # make this ready for sidekiq even if we're not using it yet
  class EventWorker
    CARD_REGEX = %r{https?://trello.com/c/([^/]+)}
    
    def perform(hook, event)
      @hook = hook
      @event = event
      puts "[hook] received for #{@event['repository']['full_name']}, no trello reference" or return nil unless card_id
      case @event['action']
      when 'closed'
        target = @hook.closed_list_id
      when 'reopened'
        target = @hook.reopened_list_id
      else
        puts "[hook] received for #{@event['repository']['full_name']}, unrecognized event #{@event['action']}"
        return nil
      end
  
      trello.put("/cards/#{card_id}/idList", value: target)
      puts "[hook] succesfully processed hook for #{@event['repository']['full_name']} with card reference #{card_id}"
    end
    
    def card_id
      return @card_id if @card_id
      return nil unless @event['issue']
      match = @event['issue']['body'].match(CARD_REGEX)
      @card_id = match ? match[1] : nil
      @card_id
    end

    def credentials
      @credentials ||= JSON.parse $redis.get("user:#{@hook.user_id}:credentials")
    end
    
    def trello
      @trello ||= Trello::Client.new(
        consumer_key: ENV['TRELLO_KEY'],
        consumer_secret: ENV['TRELLO_SECRET'],
        oauth_token: credentials['token'],
        oauth_token_secret: credentials['secret']
      )
    end
  end
  
  def credentials
    return nil unless session[:user]
    @credentials ||= JSON.parse $redis.get("user:#{session[:user][:id]}:credentials")
  end
  
  def trello
    @trello ||= Trello::Client.new(
      consumer_key: ENV['TRELLO_KEY'],
      consumer_secret: ENV['TRELLO_SECRET'],
      oauth_token: credentials['token'],
      oauth_token_secret: credentials['secret']
    )
  end

  def boards
    trello.find_many(Trello::Board, "/members/#{session[:user][:name]}/boards?fields=name")
  end

  def lists(board_id)
    trello.find_many(Trello::List, "/boards/#{board_id}/lists?fields=name")
  end

  def hooks
    ids = $redis.smembers "user:#{session[:user][:id]}:hooks"
    Hook.all(*ids)
  end

  helpers do
    def optionize(arr, selected = nil)
      arr.map{|i| "<option value='#{i.id}'#{' selected' if selected == i.id}>#{i.name}</option>"}.join("\n")
    end
  end

  get '/' do
    if session[:user]
      @boards = boards
      @hooks = hooks
      @hooks.each{|hook| hook.board_name = @boards.find{|b| b.id == hook.board_id}.name}
      erb :home
    else
      redirect '/auth/trello'
    end
  end

  get '/hooks/:id' do
    @hook = Hook.find(params[:id])
    @lists = lists(@hook.board_id)
    erb :hook
  end

  post '/hooks/:id' do
    halt 401, "Not Authorized" unless $redis.sismember "user:#{session[:user][:id]}:hooks", params[:id]
    @hook = Hook.find(params[:id])
    @hook.merge!(params[:hook])
    @hook.save
    redirect request.path
  end

  post '/hooks/:id/payload' do
    hook = Hook.find(params[:id])
    event = JSON.parse(params[:payload])
    
    EventWorker.new.perform(hook, event)
    ""
  end
  
  get '/auth/trello/callback' do
    auth_hash = env['omniauth.auth']
    session[:user] = {
      id: auth_hash.uid,
      name: auth_hash.info.nickname
    }
    $redis.set "user:#{auth_hash.uid}:credentials", {token: auth_hash.credentials.token, secret: auth_hash.credentials.secret}.to_json
    redirect '/'
  end

  post '/hooks' do
    hook = Hook.create(board_id: params[:board_id], user_id: session[:user][:id])
    $redis.sadd "user:#{session[:user][:id]}:hooks", hook.id
    redirect '/hooks/' + hook.id
  end
end