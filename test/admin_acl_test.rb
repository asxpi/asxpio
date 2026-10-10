require_relative 'test_helper'

class AdminAclTest < Minitest::Test
  include Rack::Test::Methods
  include AdminLogin

  def app
    AsxpioWeb
  end

  def setup
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    TestDb.clean_users!
    DB.connection[:bingo_incidents].delete
    @dc = Bingo::Datacenter.order(:position).first ||
          Bingo::Datacenter.create(slug: 'acl-dc', position: 1, name_ru: 'ЦОД', city_ru: 'Москва', operator: 'Op')
  end

  def as(perms)
    u = User.create(username: 'user1', password: 'user-password-1')
    perms.each do |area, flags|
      UserPermission.create(user_id: u.id, area: area.to_s,
                            **flags.to_h { |f| [:"can_#{f}", true] })
    end
    admin_login!(username: 'user1', password: 'user-password-1')
  end

  def token
    get '/admin'
    last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
  end

  def forbidden?
    last_response.status == 403
  end

  # Every registered /admin route is public, open, or mapped to an area.
  def test_every_admin_route_is_mapped
    unmapped = AsxpioWeb.routes.flat_map do |verb, routes|
      routes.map { |r| [verb, r.first.to_s] }
    end.select { |_, p| p.start_with?('/admin') }.reject do |_, p|
      sample = p.gsub(/:\w+/, 'x')
      sample.match?(AdminAuth::PUBLIC) || sample.match?(AdminAuth::OPEN) || AdminACL.area_for(sample)
    end
    assert_empty unmapped, "unmapped admin routes: #{unmapped.inspect}"
  end

  def test_perm_for
    assert_equal 'read',   AdminACL.perm_for('GET', '/admin/bingo')
    assert_equal 'write',  AdminACL.perm_for('GET', '/admin/bingo/dc/new')
    assert_equal 'write',  AdminACL.perm_for('GET', '/admin/invoices/abc/duplicate')
    assert_equal 'write',  AdminACL.perm_for('POST', '/admin/bingo/dc/1')
    assert_equal 'delete', AdminACL.perm_for('POST', '/admin/bingo/incidents/1/delete')
    assert_equal 'delete', AdminACL.perm_for('POST', '/admin/bingo/dc/1/photo/delete')
  end

  def test_bingo_read_only
    as(bingo: %i[read])
    get '/admin/bingo'
    assert last_response.ok?
    refute_includes last_response.body, 'Record incident'
    refute_includes last_response.body, 'href="/admin/invoices"'   # nav hides invoices
    get "/admin/bingo/dc/#{@dc.id}"
    assert last_response.ok?
    assert_includes last_response.body, 'disabled'
    refute_includes last_response.body, 'Danger zone'
    get '/admin/bingo/dc/new'
    assert forbidden?
    post '/admin/bingo/incidents', { authenticity_token: token, datacenter_id: @dc.id, occurred_on: '2026-10-01', kind: 'fire', title_ru: 'x' }
    assert forbidden?
    get '/admin/invoices'
    assert forbidden?
  end

  def test_read_and_delete_without_write
    inc = Bingo::Incident.create(datacenter_id: @dc.id, occurred_on: Date.today, kind: 'fire', title_ru: 'x')
    as(bingo: %i[read delete])
    post '/admin/bingo/incidents', { authenticity_token: token, datacenter_id: @dc.id, occurred_on: '2026-10-01', kind: 'fire', title_ru: 'y' }
    assert forbidden?
    get '/admin/bingo'
    assert_includes last_response.body, "/admin/bingo/incidents/#{inc.id}/delete"
    post "/admin/bingo/incidents/#{inc.id}/delete", { authenticity_token: token }
    refute forbidden?
    assert_nil Bingo::Incident[inc.id]
  end

  def test_invoices_read_only
    as(invoices: %i[read])
    get '/admin/invoices'
    assert last_response.ok?
    refute_includes last_response.body, '+ New invoice'
    get '/admin/invoices/new'
    assert forbidden?
    post '/admin/invoices', { authenticity_token: token }
    assert forbidden?
    get '/admin/bingo'
    assert forbidden?
    get '/admin'
    refute_includes last_response.body, '<h2><a href="/admin/bingo">'
  end

  def test_user_without_areas_sees_notice
    as({})
    get '/admin'
    assert last_response.ok?
    assert_includes last_response.body, 'No areas are assigned'
  end

  def test_superuser_sees_everything
    admin_login!
    get '/admin/bingo/dc/new'
    assert last_response.ok?
    get '/admin/invoices/new'
    assert last_response.ok?
  end
end
