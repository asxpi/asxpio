require 'rack/auth/basic'
require 'rack/utils'

# Rack middleware that gates everything under /admin/* behind HTTP Basic.
# Credentials come from ENV at boot; missing vars fail closed (401 always).
class AdminAuth
  def initialize(app)
    @app  = app
    @user = ENV['ADMIN_USER']
    @pass = ENV['ADMIN_PASSWORD']
  end

  def call(env)
    path = env['PATH_INFO'].to_s
    return @app.call(env) unless path == '/admin' || path.start_with?('/admin/')

    auth = Rack::Auth::Basic::Request.new(env)
    if @user && @pass && auth.provided? && auth.basic? && credentials_match?(auth.credentials)
      @app.call(env)
    else
      [401,
       { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="asxp.io admin"' },
       ["Unauthorized\n"]]
    end
  end

  private

  def credentials_match?(creds)
    user, pass = creds
    # Single & so both comparisons always run (no short-circuit timing signal).
    Rack::Utils.secure_compare(@user, user.to_s) &
      Rack::Utils.secure_compare(@pass, pass.to_s)
  end
end
