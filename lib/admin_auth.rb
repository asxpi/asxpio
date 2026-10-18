require 'rack/utils'
require_relative 'rate_limit'
require_relative 'admin_acl'

# Session login for /admin/*, replacing the old shared HTTP Basic gate.
#
# - Accounts live in `users` (lib/user.rb); the session stores user id +
#   session_version, so bumping the version logs that user out everywhere.
# - ADMIN_USER/ADMIN_PASSWORD only work while no active superuser exists
#   (first boot, or recovery); using them (re)creates that superuser.
# - Paths in PUBLIC need no login (login itself, invite/reset links).
module AdminAuth
  PUBLIC = %r{\A/admin/(login|invite/[^/]+|reset(/[^/]+)?)\z}
  # Reachable by any logged-in user regardless of permissions.
  OPEN   = %r{\A/admin(/account/password|/logout)?\z}

  class << self
    attr_writer :login_limit

    def login_limit
      @login_limit ||= RateLimit.new(limit: Integer(ENV.fetch('LOGIN_RATE_LIMIT', '10')), window: 900)
    end
  end

  module Helpers
    def current_user
      return @current_user if defined?(@current_user)
      uid = session[:uid]
      user = uid && User[uid]
      @current_user = user if user&.active && user.session_version == session[:uv]
    end

    # For views: show a form/button only if the user may use it.
    def can?(area, perm)
      current_user&.can?(area, perm) || false
    end

    def admin_path?(path = request.path_info)
      path == '/admin' || path.start_with?('/admin/')
    end

    def log_in!(user)
      session.clear # fresh session id/CSRF token after authentication
      session[:uid] = user.id
      session[:uv]  = user.session_version
      user.update(last_login_at: Time.now.utc)
      @current_user = user
    end

    def env_credentials?(username, pass)
      u, p = ENV['ADMIN_USER'].to_s, ENV['ADMIN_PASSWORD'].to_s
      return false if u.empty? || p.empty?
      Rack::Utils.secure_compare(u.downcase, username.to_s.strip.downcase) &
        Rack::Utils.secure_compare(p, pass.to_s)
    end

    def audit!(action, target = nil, detail = nil, user: current_user)
      Audit.log(action: action, user: user, target: target, detail: detail, ip: client_ip)
    end

    # Trailing slashes dropped: /admin/ has no route (see the before filter).
    def safe_next(target)
      target = target.to_s.sub(%r{(?<=.)/+\z}, '')
      target.match?(%r{\A/admin(/[\w\-/]*)?\z}) ? target : '/admin'
    end
  end

  def self.registered(app)
    app.helpers Helpers

    app.before do
      next unless admin_path?
      # One URL per page: /admin/ and /admin/bingo/ go to the slashless route.
      redirect request.fullpath.sub(%r{/+(?=\?|\z)}, ''), 301 if request.path_info.match?(%r{./\z})
      halt 503, 'Admin needs DATABASE_URL.' unless defined?(User)
      next if request.path_info.match?(PUBLIC)
      unless current_user
        redirect "/admin/login?next=#{Rack::Utils.escape(request.fullpath)}" if request.get?
        halt 401, 'Login required'
      end
      if current_user.must_change_password && !request.path_info.match?(%r{\A/admin/(account/password|logout)\z})
        redirect '/admin/account/password'
      end
      unless AdminACL.allowed?(current_user, request.request_method, request.path_info)
        halt 403, 'You do not have access to this.'
      end
    end

    app.get '/admin/login' do
      redirect '/admin' if current_user
      @page_title = 'Log in · admin'
      @noindex    = true
      @next       = safe_next(params[:next])
      erb :'admin/login'
    end

    app.post '/admin/login' do
      @next = safe_next(params[:next])
      unless AdminAuth.login_limit.allow?(client_ip)
        @error = 'Too many attempts. Try again in 15 minutes.'
        status 429
        return erb :'admin/login'
      end
      user = User.authenticate(params[:username], params[:password])
      if !user && !User.active_superuser? && env_credentials?(params[:username], params[:password])
        # Recovery: no usable superuser left, so the env credentials restore one.
        name = ENV['ADMIN_USER'].strip.downcase
        user = User[username: name] || User.new(username: name)
        user.set(superuser: true, active: true)
        user.password = ENV['ADMIN_PASSWORD']
        user.save
        $logger.warn("users: emergency login restored superuser #{name} from #{client_ip}")
        audit!('auth.emergency_login', name, user: user)
      end
      if user
        log_in!(user)
        audit!('auth.login')
        redirect @next
      else
        $logger.info("users: failed login for #{params[:username].to_s[0, 64].inspect} from #{client_ip}")
        Audit.log(action: 'auth.login_failed', username: params[:username].to_s[0, 64], ip: client_ip)
        @error = 'Wrong username or password.'
        status 401
        erb :'admin/login'
      end
    end

    app.post '/admin/logout' do
      audit!('auth.logout') if current_user
      session.clear
      redirect '/admin/login'
    end

    app.get '/admin/account/password' do
      @page_title = 'Change password · admin'
      @noindex    = true
      erb :'admin/account_password'
    end

    app.post '/admin/account/password' do
      u = current_user
      @error =
        if !u.authenticate(params[:current])        then 'Current password is wrong.'
        elsif params[:password].to_s.length < User::MIN_PASS then "New password needs at least #{User::MIN_PASS} characters."
        elsif params[:password] != params[:confirm] then 'Passwords do not match.'
        end
      if @error
        @page_title = 'Change password · admin'
        @noindex    = true
        status 422
        return erb :'admin/account_password'
      end
      u.password = params[:password]
      u.must_change_password = false
      u.session_version += 1 # other sessions out
      u.save
      log_in!(u)
      audit!('auth.password_changed')
      redirect '/admin'
    end
  end
end
