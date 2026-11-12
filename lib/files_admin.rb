# /admin/files: publish files to the public bucket and manage them.
# Registered into AsxpioWeb, so AdminAuth, the ACL (area "files") and CSRF
# apply.
module FilesAdmin
  module Helpers
    def uploads(value)
      (value.is_a?(Hash) ? [value] : Array(value)).select { |f| f.is_a?(Hash) && f[:tempfile] }
    end

    def read_upload(upload)
      upload[:tempfile].read(PublicFile.max_bytes + 1) || ''
    end

    def note_param
      note = params[:note].to_s.strip[0, 500]
      note.empty? ? nil : note
    end

    def fmt_bytes(n)
      return "#{n} B" if n < 1024
      return format('%.1f kB', n / 1024.0) if n < 1024**2
      format('%.1f MB', n / 1024.0**2)
    end
  end

  def self.registered(app)
    app.helpers Helpers

    app.get '/admin/files' do
      @page_title = 'Files · admin'
      @noindex    = true
      @files      = PublicFile.order(Sequel.desc(:created_at), Sequel.desc(:id)).all
      @flash      = session.delete(:files_flash)
      erb :'admin/files/index'
    end

    app.post '/admin/files' do
      list = uploads(params[:files])
      done, failed = [], []
      list.each do |up|
        file = PublicFile.publish(up[:filename], read_upload(up), by: current_user.username,
                                  note: note_param, strip: params[:keep_metadata] != '1')
        audit!('files.upload', file.key, "#{file.size} bytes")
        done << file.filename
      rescue PublicFile::Error => e
        failed << e.message
      end
      failed << 'no file chosen' if list.empty?
      session[:files_flash] = [("Published #{done.join(', ')}." if done.any?), *failed].compact.join(' | ')
      redirect '/admin/files'
    end

    app.get '/admin/files/:id' do
      @file = PublicFile[params[:id].to_i] or halt 404
      @page_title = "#{@file.filename} · files admin"
      @noindex    = true
      @flash      = session.delete(:files_flash)
      erb :'admin/files/show'
    end

    # Edits the note and, when a file is sent, replaces the contents under
    # the same URL. The extension has to match: it decides how the object
    # is served.
    app.post '/admin/files/:id' do
      file = PublicFile[params[:id].to_i] or halt 404
      begin
        if (up = uploads(params[:file]).first)
          if PublicFile.ext_of(PublicFile.clean_name(up[:filename])) != PublicFile.ext_of(file.filename)
            raise PublicFile::Error, "the replacement must be a .#{PublicFile.ext_of(file.filename)} file; publish other types as a new file"
          end
          file.store!(read_upload(up), by: current_user.username, strip: params[:keep_metadata] != '1')
          audit!('files.replace', file.key, "#{file.size} bytes")
        end
        if file.note != note_param
          file.update(note: note_param, updated_at: Time.now.utc)
          audit!('files.edit', file.key, file.note)
        end
        session[:files_flash] = 'Saved.'
      rescue PublicFile::Error => e
        session[:files_flash] = "Not saved: #{e.message}"
      end
      redirect "/admin/files/#{file.id}"
    end

    app.post '/admin/files/:id/delete' do
      file = PublicFile[params[:id].to_i] or halt 404
      file.remove!
      audit!('files.delete', file.key, "#{file.size} bytes")
      session[:files_flash] = "Deleted #{file.filename}; its link no longer works."
      redirect '/admin/files'
    end
  end
end
