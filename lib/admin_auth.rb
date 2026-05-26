require 'rack/auth/basic'

# Rack middleware that gates everything under /admin/* behind HTTP Basic.
# Credentials come from ENV at boot; missing vars fail closed (401 always).
class AdminAuth
  def initialize(app)
    @app  = app
    @user = ENV['ADMIN_USER']
    @pass = ENV['ADMIN_PASSWORD']
  end

  def call(env)
    return @app.call(env) unless env['PATH_INFO'].to_s.start_with?('/admin')

    auth = Rack::Auth::Basic::Request.new(env)
    if @user && @pass && auth.provided? && auth.basic? && auth.credentials == [@user, @pass]
      @app.call(env)
    else
      [401,
       { 'content-type' => 'text/plain', 'www-authenticate' => 'Basic realm="asxp.io admin"' },
       ["Unauthorized\n"]]
    end
  end
end
