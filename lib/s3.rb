require 'aws-sdk-s3'

module S3
  module_function

  def client
    @client ||= Aws::S3::Client.new(
      region:           ENV.fetch('S3_REGION', 'us-east-1'),
      endpoint:         ENV.fetch('S3_ENDPOINT'),
      access_key_id:    ENV.fetch('S3_ACCESS_KEY'),
      secret_access_key: ENV.fetch('S3_SECRET_KEY'),
      force_path_style: true
    )
  end

  # Separate client whose endpoint is the public hostname; used only to mint
  # presigned URLs that a browser can dereference. Bytes never travel through
  # this client.
  def presign_client
    @presign_client ||= Aws::S3::Client.new(
      region:           ENV.fetch('S3_REGION', 'us-east-1'),
      endpoint:         ENV.fetch('S3_PUBLIC_ENDPOINT'),
      access_key_id:    ENV.fetch('S3_ACCESS_KEY'),
      secret_access_key: ENV.fetch('S3_SECRET_KEY'),
      force_path_style: true
    )
  end

  def bucket
    ENV.fetch('S3_BUCKET')
  end

  def put(key, bytes, content_type: 'application/pdf')
    client.put_object(
      bucket:       bucket,
      key:          key,
      body:         bytes,
      content_type: content_type
    )
    key
  end

  def exists?(key)
    client.head_object(bucket: bucket, key: key)
    true
  rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
    false
  end

  def presigned_url(key, expires_in: 300, filename: nil)
    params = { bucket: bucket, key: key }
    if filename
      params[:response_content_disposition] = %(attachment; filename="#{filename}")
    end
    Aws::S3::Presigner.new(client: presign_client).presigned_url(:get_object, **params, expires_in: expires_in)
  end
end
