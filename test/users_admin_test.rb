require_relative 'test_helper'

class UsersAdminTest < Minitest::Test
  include Rack::Test::Methods
  include AdminLogin

  def app
    AsxpioWeb
  end

  def setup
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    TestDb.clean_users!
    DB.connection[:audit_log].delete
    Mail::TestMailer.deliveries.clear
  end

  def token(path = '/admin/users')
    get path
    last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
  end

  def create_user(params)
    post '/admin/users', { authenticity_token: token('/admin/users/new') }.merge(params)
  end

  def invite_url
    Mail::TestMailer.deliveries.last.body.to_s[%r{https?://\S+/admin/invite/\S+}]
  end

  def test_superuser_creates_user_and_invite_is_emailed_and_shown
    admin_login!
    create_user(username: 'carol', email: 'carol@example.com', perm: { 'bingo' => { 'read' => '1', 'delete' => '1' } })
    assert_equal 302, last_response.status
    carol = User[username: 'carol']
    assert carol.can?('bingo', 'read')
    assert carol.can?('bingo', 'delete')
    refute carol.can?('bingo', 'write')
    assert_nil carol.password_digest
    assert_equal ['carol@example.com'], Mail::TestMailer.deliveries.last.to
    assert_equal 'asxp.io admin', Mail::TestMailer.deliveries.last[:from].display_names.first
    assert_equal ['test@example.com'], Mail::TestMailer.deliveries.last.from
    get '/admin/users'
    assert_includes last_response.body, 'emailed to carol@example.com'
    assert_includes last_response.body, '/admin/invite/'
    get '/admin/users'
    refute_includes last_response.body, '/admin/invite/'   # shown once
  end

  def test_invite_without_username_lets_invitee_choose
    admin_login!
    create_user(username: '', perm: { 'bingo' => { 'read' => '1' } })
    u = User.where(choose_username: true).first
    assert_match(/\Ainvite-[0-9a-f]{8}\z/, u.username)
    get '/admin/users'
    link = last_response.body[%r{https?://\S+?/admin/invite/[\w-]+}]
    assert link, 'invite link shown'
    path = URI(link).path
    clear_cookies
    get path
    assert_includes last_response.body, 'Choose a username'
    tok = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    post path, { authenticity_token: tok, username: ENV['ADMIN_USER'], password: 'kate-password-12', confirm: 'kate-password-12' }
    assert_equal 422, last_response.status                 # taken
    post path, { authenticity_token: tok, username: 'invite-x', password: 'kate-password-12', confirm: 'kate-password-12' }
    assert_equal 422, last_response.status                 # reserved prefix
    post path, { authenticity_token: tok, username: 'Kate', password: 'kate-password-12', confirm: 'kate-password-12' }
    assert_equal 302, last_response.status
    u.refresh
    assert_equal 'kate', u.username
    refute u.choose_username
    assert u.can?('bingo', 'read')
  end

  def test_delete_implies_read
    admin_login!
    create_user(username: 'dave', perm: { 'bingo' => { 'delete' => '1' } })
    assert User[username: 'dave'].can?('bingo', 'read')
  end

  def test_invite_accept_sets_password_and_is_single_use
    admin_login!
    create_user(username: 'carol', email: 'carol@example.com')
    path = URI(invite_url).path
    clear_cookies
    get path
    assert last_response.ok?
    assert_includes last_response.body, 'carol'
    tok = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    post path, { authenticity_token: tok, password: 'short', confirm: 'short' }
    assert_equal 422, last_response.status
    post path, { authenticity_token: tok, password: 'carol-password-1', confirm: 'carol-password-1' }
    assert_equal 302, last_response.status
    assert User[username: 'carol'].authenticate('carol-password-1')
    get '/admin'
    assert last_response.ok?                               # logged in
    clear_cookies
    get path
    assert_equal 404, last_response.status                 # used
  end

  def test_expired_invite_rejected
    u = User.create(username: 'erin')
    raw = UserToken.issue!(u, 'invite')
    UserToken.where(user_id: u.id).update(expires_at: Time.now.utc - 1)
    get "/admin/invite/#{raw}"
    assert_equal 404, last_response.status
  end

  def test_reset_request_same_answer_and_mails_only_real_accounts
    User.create(username: 'frank', email: 'frank@example.com', password: 'frank-password-1')
    get '/admin/reset'
    tok = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    post '/admin/reset', { authenticity_token: tok, login: 'nobody' }
    nobody = last_response.body
    post '/admin/reset', { authenticity_token: tok, login: 'frank@example.com' }
    assert_equal nobody.scan(/reset link is on its way/), last_response.body.scan(/reset link is on its way/)
    assert_equal 1, Mail::TestMailer.deliveries.size
    url = Mail::TestMailer.deliveries.last.body.to_s[%r{https?://\S+/admin/reset/\S+}]
    get URI(url).path
    assert last_response.ok?, "#{url.inspect} -> #{last_response.status} #{last_response.body[0, 200]}"
  end

  def test_no_escalation_by_user_manager
    boss = User.create(username: 'manager', password: 'manager-pass-1')
    UserPermission.create(user_id: boss.id, area: 'users', can_read: true, can_write: true)
    UserPermission.create(user_id: boss.id, area: 'bingo', can_read: true)
    target = User.create(username: 'grace', password: 'grace-password-1')
    UserPermission.create(user_id: target.id, area: 'invoices', can_read: true)
    admin_login!(username: 'manager', password: 'manager-pass-1')

    create_user(username: 'henry', superuser: '1', perm: { 'invoices' => { 'write' => '1' }, 'bingo' => { 'read' => '1' } })
    henry = User[username: 'henry']
    refute henry.superuser
    refute henry.can?('invoices', 'write')                 # manager lacks it
    assert henry.can?('bingo', 'read')

    post "/admin/users/#{target.id}", { authenticity_token: token, name: 'G', active: '1', perm: { 'bingo' => { 'read' => '1' } } }
    target.refresh
    assert target.can?('invoices', 'read')                 # kept: manager can't touch it
    assert target.can?('bingo', 'read')

    root = User.create(username: 'root', superuser: true, password: 'root-password-11')
    post "/admin/users/#{root.id}", { authenticity_token: token, name: 'x', active: '' }
    assert_equal 403, last_response.status
  end

  def test_cannot_delete_self_or_last_superuser
    admin_login!
    me = User[username: ENV['ADMIN_USER']]
    post "/admin/users/#{me.id}/delete", { authenticity_token: token }
    assert_equal 422, last_response.status
    other = User.create(username: 'other', superuser: true, password: 'other-password-1')
    post "/admin/users/#{other.id}/delete", { authenticity_token: token }
    assert_equal 302, last_response.status
    assert_nil User[other.id]
  end

  def test_disabling_logs_user_out
    admin_login!
    u = User.create(username: 'ivan', password: 'ivan-password-12')
    v = u.session_version
    post "/admin/users/#{u.id}", { authenticity_token: token, name: '', email: '' } # active unticked
    u.refresh
    refute u.active
    assert_equal v + 1, u.session_version
  end

  def test_audit_log_records_and_lists
    admin_login!
    create_user(username: 'judy')
    actions = DB.connection[:audit_log].select_map(:action)
    assert_includes actions, 'auth.login'
    assert_includes actions, 'user.create'
    get '/admin/audit'
    assert last_response.ok?
    assert_includes last_response.body, 'user.create'
    assert_includes last_response.body, 'judy'
  end

  def test_superuser_renames_including_self
    admin_login!
    me = User[username: ENV['ADMIN_USER']]
    post "/admin/users/#{me.id}", { authenticity_token: token, username: 'Renamed', name: '' }
    assert_equal 'renamed', me.refresh.username
    get '/admin'
    assert last_response.ok?                               # session survives
    other = User.create(username: 'taken', password: 'taken-password-1')
    post "/admin/users/#{me.id}", { authenticity_token: token, username: 'taken', name: '' }
    assert_equal 'renamed', me.refresh.username            # duplicate refused
    assert_includes DB.connection[:audit_log].select_map(:action), 'user.rename'
  end

  def test_non_superuser_cannot_rename
    boss = User.create(username: 'manager', password: 'manager-pass-1')
    UserPermission.create(user_id: boss.id, area: 'users', can_read: true, can_write: true)
    t = User.create(username: 'target', password: 'target-password1')
    admin_login!(username: 'manager', password: 'manager-pass-1')
    post "/admin/users/#{t.id}", { authenticity_token: token, username: 'hijacked', name: '', active: '1' }
    assert_equal 'target', t.refresh.username
  end

  def test_users_read_only_cannot_create
    u = User.create(username: 'viewer', password: 'viewer-password1')
    UserPermission.create(user_id: u.id, area: 'users', can_read: true)
    admin_login!(username: 'viewer', password: 'viewer-password1')
    get '/admin/users'
    assert last_response.ok?
    refute_includes last_response.body, '+ New user'
    get '/admin/users/new'
    assert_equal 403, last_response.status
  end
end
