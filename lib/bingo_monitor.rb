require 'socket'

module Bingo
  # Reachability monitor for datacenterbingo's status page. Every minute
  # bin/monitor opens one TCP connection to each active target; a handshake
  # or a refusal both prove the site's network answers. Results fold into
  # 5-minute rows per datacenter (upserts, so a restart mid-bucket merges).
  module Monitor
    INTERVAL  = 60   # seconds between rounds
    BUCKET    = 300  # seconds per sample row
    TIMEOUT   = 3    # connect and DNS timeout per probe
    THREADS   = 32
    KEEP_DAYS = 30
    CONTROL   = '_control'.freeze # slug for control hosts in the bulk form

    class Target < Sequel::Model(:bingo_monitor_targets)
      many_to_one :datacenter, class: 'Bingo::Datacenter'

      def before_create
        self.created_at ||= Time.now.utc
        super
      end

      def control? = datacenter_id.nil?
      def endpoint = "#{host}:#{port}"
    end

    module_function

    def bucket_of(time) = Time.at(time.to_i - (time.to_i % BUCKET)).utc

    # Handshake time in ms, or nil when nothing answered (timeout, no route,
    # DNS failure). A refusal is an answer: the host is up, the port closed.
    def probe(host, port)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        Socket.tcp(host, port, connect_timeout: TIMEOUT, resolv_timeout: TIMEOUT, &:close)
      rescue Errno::ECONNREFUSED
        nil # fall through to the elapsed time
      end
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round
    rescue SystemCallError, SocketError, IOError
      nil
    end

    # [[target, ms or nil], ...], probed concurrently.
    def round(targets)
      queue = Queue.new
      targets.each { |t| queue << t }
      results = Queue.new
      Array.new([THREADS, targets.size].min) do
        Thread.new do
          while (t = (queue.pop(true) rescue nil))
            results << [t, probe(t.host, t.port)]
          end
        end
      end.each(&:join)
      Array.new(results.size) { results.pop }
    end

    def record!(results, at: Time.now.utc)
      db = DB.connection
      bucket = bucket_of(at)
      db.transaction do
        sites, controls = results.partition { |t, _| t.datacenter_id }
        sites.group_by { |t, _| t.datacenter_id }.each do |dc_id, rs|
          answered = rs.filter_map { |_, ms| ms }
          upsert(db[:bingo_monitor_samples], %i[datacenter_id bucket_at],
                 { datacenter_id: dc_id, bucket_at: bucket },
                 checks: rs.size, ok: answered.size, rtt_ms_sum: answered.sum)
        end
        upsert(db[:bingo_monitor_buckets], %i[bucket_at], { bucket_at: bucket },
               rounds: 1, control_checks: controls.size, control_ok: controls.count { |_, ms| ms })
        results.each do |t, ms|
          change = t.last_ok.nil? || t.last_ok != !ms.nil?
          db[:bingo_monitor_targets].where(id: t.id).update(
            { last_ok: !ms.nil?, last_rtt_ms: ms, last_checked_at: at }.merge(change ? { last_change_at: at } : {})
          )
        end
      end
    end

    # Insert key+counters, or add the counters to the existing row.
    def upsert(ds, key_cols, key, counters)
      t = ds.first_source_table
      ds.insert_conflict(target: key_cols,
                         update: counters.keys.to_h { |c| [c, Sequel[t][c] + Sequel[:excluded][c]] })
        .insert(key.merge(counters))
    end

    def prune!(now = Time.now.utc)
      cutoff = now - (KEEP_DAYS * 86_400)
      DB.connection[:bingo_monitor_samples].where { bucket_at < cutoff }.delete
      DB.connection[:bingo_monitor_buckets].where { bucket_at < cutoff }.delete
    end

    # Bulk form, one target per line: "slug host[:port] source_url label…".
    # slug "_control" adds a control host. Returns [targets_attrs, errors].
    def parse(text)
      slugs = Datacenter.select_hash(:slug, :id)
      attrs, errors = [], []
      text.to_s.each_line.with_index(1) do |line, n|
        line = line.strip
        next if line.empty? || line.start_with?('#')
        slug, hostport, url, *label = line.split(/\s+/)
        host, port = hostport.to_s.match(/\A\[?([^\]]+?)\]?(?::(\d+))?\z/)&.captures
        dc_id = slug == CONTROL ? nil : slugs[slug]
        err = if slug != CONTROL && !dc_id then "unknown slug #{slug.inspect}"
              elsif host.to_s.empty? then 'no host'
              elsif url && !url.match?(%r{\Ahttps?://}) then 'source must be an http(s) URL'
              end
        if err
          errors << "line #{n}: #{err}"
        else
          attrs << { datacenter_id: dc_id, host: host, port: (port || 443).to_i, source_url: url,
                     label: (label.join(' ') unless label.empty?) }
        end
      end
      [attrs, errors]
    end
  end
end
