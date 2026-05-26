require 'sequel'

module DB
  module_function

  def connect!
    @connection ||= Sequel.connect(
      ENV.fetch('DATABASE_URL'),
      max_connections: 5,
      logger:          ($env == 'development' ? $logger : nil)
    )
  end

  def connection
    @connection or raise 'DB not connected — call DB.connect! first'
  end

  def migrate!
    Sequel.extension :migration
    Sequel::Migrator.run(connection, File.join($root, 'db', 'migrations'))
  end
end
