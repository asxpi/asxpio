# /admin/users (manage accounts), /admin/audit, and the public one-time
# invite / password-reset pages. Registered into AsxpioWeb after AdminAuth.
module UsersAdmin
  module Helpers
    # Permission flags from the form. The acting user can only change flags
    # they hold themselves (no escalation); any other flag keeps the target's
    # current value. Ticking delete implies read.
    def permission_params(target = nil)
      User::AREAS.to_h do |area|
        flags = User::PERMS.select do |f|
          if current_user.can?(area, f) then params.dig('perm', area, f) == '1'
          else target&.can?(area, f) || false
          end
        end
        flags |= ['read'] if flags.include?('delete')
        [area, flags]
      end
    end

    def save_permissions!(user, perms)
      UserPermission.where(user_id: user.id).delete
      perms.each do |area, flags|
        next if flags.empty?
        UserPermission.create(user_id: user.id, area: area, **flags.to_h { |f| [:"can_#{f}", true] })
      end
    end

    def perm_summary(user)
      return 'superuser' if user.superuser
      user.permissions.map do |p|
        f = User::PERMS.select { |x| p[:"can_#{x}"] }.map { |x| x[0] }.join
        f.empty? ? nil : "#{p.area}: #{f}"
      end.compact.join(' · ').then { |s| s.empty? ? 'no access' : s }
    end

    # Email the link if possible; the acting admin also sees it once, so an
    # account without email (or a failed send) can still be onboarded.
    def send_account_link(user, kind)
      raw = UserToken.issue!(user, kind)
      url = "#{request.base_url}/admin/#{kind}/#{raw}"
      sent = false
      if user.email
        begin
          Mailer.account_link(to: user.email, username: user.username, url: url, kind: kind)
          sent = true
        rescue StandardError => e
          $logger.error("users: #{kind} mail to #{user.email} failed: #{e.class}: #{e.message}")
        end
      end
      session[:users_link] = { 'url' => url, 'sent' => sent, 'to' => user.email, 'kind' => kind }
    end

    def manageable!(user)
      halt 403, 'Only superusers can change superuser accounts.' if user.superuser && !current_user.superuser
    end

    def set_password_page(purpose)
      @token = UserToken.find_valid(params[:token], purpose) or halt 404, 'This link is invalid or has expired.'
      @purpose = purpose
      @page_title = purpose == 'invite' ? 'Set your password' : 'Reset password'
      @noindex = true
    end
  end

  def self.registered(app)
    app.helpers Helpers

    app.get '/admin/users' do
      @page_title = 'Users · admin'
      @noindex    = true
      @users      = User.order(:username).eager(:permissions).all
      @flash      = session.delete(:users_flash)
      @link       = session.delete(:users_link)
      erb :'admin/users/index'
    end

    app.get '/admin/users/new' do
      @user = User.new
      @page_title = 'New user · admin'
      @noindex = true
      erb :'admin/users/form'
    end

    app.post '/admin/users' do
      @user = User.new(username: params[:username].to_s.strip.downcase, name: params[:name].to_s.strip,
                       email: params[:email].to_s.strip.downcase.then { |e| e.empty? ? nil : e })
      @user.superuser = params[:superuser] == '1' if current_user.superuser
      unless @user.valid? && !User[username: @user.username] && !(@user.email && User[email: @user.email])
        @error = @user.errors.full_messages.join('; ').then { |m| m.empty? ? 'Username or email already in use.' : m }
        @page_title = 'New user · admin'
        @noindex = true
        status 422
        return erb :'admin/users/form'
      end
      @user.save
      save_permissions!(@user, permission_params) unless @user.superuser
      send_account_link(@user, 'invite')
      audit!('user.create', @user.username, perm_summary(@user.refresh))
      redirect '/admin/users'
    end

    app.get '/admin/users/:id' do
      @user = User[params[:id].to_i] or halt 404
      @page_title = "#{@user.username} · admin"
      @noindex = true
      @flash = session.delete(:users_flash)
      erb :'admin/users/form'
    end

    app.post '/admin/users/:id' do
      user = User[params[:id].to_i] or halt 404
      manageable!(user)
      self_edit = user.id == current_user.id
      before = perm_summary(user)
      old_name = user.username
      # Superusers may rename accounts; login sessions survive (they key on id).
      if current_user.superuser && params[:username] && !params[:username].strip.empty?
        user.username = params[:username].strip.downcase
      end
      user.name  = params[:name].to_s.strip
      user.email = params[:email].to_s.strip.downcase.then { |e| e.empty? ? nil : e }
      unless self_edit # you can't lock yourself out
        active = params[:active] == '1'
        user.session_version += 1 if user.active && !active
        user.active = active
        user.superuser = params[:superuser] == '1' if current_user.superuser
      end
      taken = User.exclude(id: user.id).where(username: user.username).any? ||
              (user.email && User.exclude(id: user.id).where(email: user.email).any?)
      if !user.valid? || taken
        session[:users_flash] = user.errors.full_messages.join('; ').then { |m| m.empty? ? 'Username or email already in use.' : m }
        redirect "/admin/users/#{user.id}"
      end
      perms = permission_params(user) # read before saving changes
      user.save
      save_permissions!(user, perms) unless user.superuser
      audit!('user.rename', user.username, "#{old_name} → #{user.username}") if old_name != user.username
      audit!('user.update', user.username, "#{before} → #{perm_summary(user.refresh)}#{' (disabled)' unless user.active}")
      session[:users_flash] = 'Saved.'
      redirect "/admin/users/#{user.id}"
    end

    app.post '/admin/users/:id/invite' do
      user = User[params[:id].to_i] or halt 404
      manageable!(user)
      kind = user.password_digest ? 'reset' : 'invite'
      send_account_link(user, kind)
      audit!("user.#{kind}_link", user.username)
      redirect '/admin/users'
    end

    app.post '/admin/users/:id/delete' do
      user = User[params[:id].to_i] or halt 404
      manageable!(user)
      halt 422, "You can't delete yourself." if user.id == current_user.id
      if user.superuser && User.where(superuser: true, active: true).exclude(id: user.id).empty?
        halt 422, "Can't delete the last active superuser."
      end
      user.destroy
      audit!('user.delete', user.username)
      session[:users_flash] = "Deleted #{user.username}."
      redirect '/admin/users'
    end

    app.get '/admin/audit' do
      @page_title = 'Audit log · admin'
      @noindex = true
      @entries = Audit.recent
      erb :'admin/audit'
    end

    # --- public: invite / reset links -----------------------------------

    %w[invite reset].each do |purpose|
      app.get "/admin/#{purpose}/:token" do
        set_password_page(purpose)
        erb :'admin/set_password'
      end

      app.post "/admin/#{purpose}/:token" do
        set_password_page(purpose)
        @error =
          if params[:password].to_s.length < User::MIN_PASS then "Password needs at least #{User::MIN_PASS} characters."
          elsif params[:password] != params[:confirm]       then 'Passwords do not match.'
          end
        if @error
          status 422
          return erb :'admin/set_password'
        end
        user = @token.user
        user.password = params[:password]
        user.must_change_password = false
        user.session_version += 1
        user.save
        @token.use!
        log_in!(user)
        audit!("user.#{purpose}_accepted", user.username)
        redirect '/admin'
      end
    end

    app.get '/admin/reset' do
      @page_title = 'Reset password'
      @noindex = true
      erb :'admin/reset_request'
    end

    # Same answer whether or not the account exists (no enumeration).
    app.post '/admin/reset' do
      @page_title = 'Reset password'
      @noindex = true
      if AdminAuth.login_limit.allow?(client_ip)
        q = params[:login].to_s.strip.downcase
        user = User.where(active: true).where(Sequel.|({ username: q }, { email: q })).first
        if user&.email && user.password_digest
          url = "#{request.base_url}/admin/reset/#{UserToken.issue!(user, 'reset')}"
          begin
            Mailer.account_link(to: user.email, username: user.username, url: url, kind: 'reset')
          rescue StandardError => e
            $logger.error("users: reset mail failed: #{e.class}: #{e.message}")
          end
          Audit.log(action: 'user.reset_requested', user: user, ip: client_ip)
        end
      end
      @sent = true
      erb :'admin/reset_request'
    end
  end
end
