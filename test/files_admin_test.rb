require_relative 'test_helper'

class FilesAdminTest < Minitest::Test
  include Rack::Test::Methods
  include AdminLogin

  def app
    AsxpioWeb
  end

  def setup
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    TestDb.clean_users!
    DB.connection[:public_files].delete
    DB.connection[:audit_log].delete
    ENV['PUBLIC_S3_BUCKET'] = 'public'
    ENV['PUBLIC_BASE_URL']  = 'https://s3.example/public'
  end

  def teardown
    %w[PUBLIC_S3_BUCKET PUBLIC_BASE_URL PUBLIC_MAX_MB PUBLIC_QUOTA_MB].each { |k| ENV.delete(k) }
  end

  def token
    get '/admin/files'
    last_response.body[/name="authenticity_token" value="([^"]+)"/, 1] ||
      (get('/admin'); last_response.body[/name="authenticity_token" value="([^"]+)"/, 1])
  end

  def upload(name, data = 'hello')
    Rack::Test::UploadedFile.new(StringIO.new(data), 'application/octet-stream', true, original_filename: name)
  end

  # Runs the block with S3 puts and deletes recorded instead of sent.
  def recording
    puts_to, deleted = [], []
    S3.client.stub(:put_object, ->(**o) { puts_to << o }) do
      S3.client.stub(:delete_object, ->(**o) { deleted << o }) { yield puts_to, deleted }
    end
  end

  def as(flags)
    u = User.create(username: 'user1', password: 'user-password-1')
    UserPermission.create(user_id: u.id, area: 'files', **flags.to_h { |f| [:"can_#{f}", true] })
    admin_login!(username: 'user1', password: 'user-password-1')
  end

  def test_clean_name
    assert_equal 'My-report-v2.pdf', PublicFile.clean_name('C:\\tmp\\My report (v2).PDF')
    assert_equal 'passwd',           PublicFile.clean_name('../../etc/passwd')
    assert_equal 'file.png',         PublicFile.clean_name('отчёт.png')
    assert_equal 'file',             PublicFile.clean_name('')
  end

  def test_publish_inline_and_download
    admin_login!
    recording do |puts_to, _|
      post '/admin/files', { authenticity_token: token, note: 'for the client',
                             files: [upload('Spec sheet.pdf', '%PDF-1.4'), upload('page.html', '<script>1</script>'), upload('logo.svg', '<svg/>')] }
      assert last_response.redirect?
      pdf, html, svg = puts_to
      assert_equal %w[public public public], puts_to.map { |o| o[:bucket] }
      assert_match %r{\A[0-9a-f]{8}/Spec-sheet\.pdf\z}, pdf[:key]
      assert_equal ['application/pdf', 'inline'], pdf.values_at(:content_type, :content_disposition)
      [html, svg].each do |o|
        assert_equal 'application/octet-stream', o[:content_type]
        assert_match(/\Aattachment; filename=/, o[:content_disposition])
      end
    end
    row = PublicFile.first(filename: 'Spec-sheet.pdf')
    assert_equal [8, true, 'for the client', ENV['ADMIN_USER']], [row.size, row.inline, row.note, row.uploaded_by]
    assert_equal Digest::SHA256.hexdigest('%PDF-1.4'), row.sha256
    assert_equal "https://s3.example/public/#{row.key}", row.url
    get '/admin/files'
    assert_includes last_response.body, row.url
    assert_equal 3, DB.connection[:audit_log].where(action: 'files.upload').count
    get '/admin'
    assert_includes last_response.body, '<h2><a href="/admin/files">'
  end

  def test_metadata_is_stripped_unless_kept
    jpeg = "\xFF\xD8".b + "\xFF\xE1\x00\x08Exif\x00\x00".b + "\xFF\xDB\x00\x04\x01\x02".b + "\xFF\xD9".b
    admin_login!
    recording do |puts_to, _|
      post '/admin/files', { authenticity_token: token, files: [upload('a.jpg', jpeg)] }
      post '/admin/files', { authenticity_token: token, files: [upload('b.jpg', jpeg)], keep_metadata: '1' }
      refute_includes puts_to[0][:body], 'Exif'
      assert_includes puts_to[1][:body], 'Exif'
    end
  end

  def test_limits
    admin_login!
    ENV['PUBLIC_MAX_MB'] = '1'
    recording do |puts_to, _|
      post '/admin/files', { authenticity_token: token, files: [upload('big.bin', 'x' * (1024 * 1024 + 1)), upload('empty.txt', '')] }
      assert_empty puts_to
      get '/admin/files'
      assert_includes last_response.body, 'big.bin: larger than 1 MB'
      assert_includes last_response.body, 'empty.txt: empty file'

      ENV['PUBLIC_QUOTA_MB'] = '1'
      post '/admin/files', { authenticity_token: token, files: [upload('a.bin', 'x' * 700_000)] }
      post '/admin/files', { authenticity_token: token, files: [upload('b.bin', 'x' * 700_000)] }
      assert_equal ['a.bin'], PublicFile.select_map(:filename)
      get '/admin/files'
      assert_includes last_response.body, 'quota is used up'
    end
  end

  def test_edit_replace_and_delete
    admin_login!
    recording do |puts_to, deleted|
      post '/admin/files', { authenticity_token: token, files: [upload('notes.txt', 'one')] }
      file = PublicFile.first
      post "/admin/files/#{file.id}", { authenticity_token: token, note: 'v2', file: upload('other-name.txt', 'two!') }
      file.refresh
      assert_equal ['v2', 4, Digest::SHA256.hexdigest('two!')], [file.note, file.size, file.sha256]
      assert_equal [file.key, file.key], puts_to.map { |o| o[:key] }           # same link

      post "/admin/files/#{file.id}", { authenticity_token: token, note: 'v2', file: upload('x.pdf', '%PDF') }
      assert_equal 4, file.refresh.size                                        # other type refused
      get "/admin/files/#{file.id}"
      assert_includes last_response.body, 'must be a .txt file'

      post "/admin/files/#{file.id}/delete", { authenticity_token: token }
      assert_nil PublicFile[file.id]
      assert_equal [{ bucket: 'public', key: file.key }], deleted
    end
    assert_equal %w[files.delete files.edit files.replace files.upload],
                 DB.connection[:audit_log].where(Sequel.like(:action, 'files.%')).select_order_map(:action)
  end

  def test_permissions
    PublicFile.create(key: 'aaaaaaaa/a.txt', filename: 'a.txt', content_type: 'text/plain', size: 1, sha256: 'x',
                      created_at: Time.now.utc, updated_at: Time.now.utc)
    file = PublicFile.first
    as(%i[read])
    get '/admin/files'
    assert last_response.ok?
    refute_includes last_response.body, 'Publish'
    get "/admin/files/#{file.id}"
    assert last_response.ok?
    refute_includes last_response.body, 'Danger zone'
    post '/admin/files', { authenticity_token: token, files: [upload('b.txt')] }
    assert_equal 403, last_response.status
    post "/admin/files/#{file.id}/delete", { authenticity_token: token }
    assert_equal 403, last_response.status
    get '/admin/invoices'
    assert_equal 403, last_response.status
  end
end
