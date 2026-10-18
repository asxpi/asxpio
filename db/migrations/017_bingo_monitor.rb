Sequel.migration do
  up do
    # Reachability monitor behind datacenterbingo's status page (bin/monitor
    # writes, the public site reads). A target is a host a public source ties
    # to one datacenter; datacenter_id NULL marks a control host in Russia
    # that belongs to no listed site, so "site down" can be told apart from
    # "our vantage point lost Russia".
    create_table :bingo_monitor_targets do
      primary_key :id
      foreign_key :datacenter_id, :bingo_datacenters, on_delete: :cascade
      String    :host, null: false
      Integer   :port, null: false, default: 443
      String    :label
      String    :source_url
      TrueClass :active, null: false, default: true
      TrueClass :last_ok
      Integer   :last_rtt_ms
      DateTime  :last_checked_at
      DateTime  :last_change_at
      DateTime  :created_at, null: false
      index :datacenter_id
    end

    # Per datacenter per 5-minute bucket: probes sent, probes answered and
    # the summed handshake time of the answered ones.
    create_table :bingo_monitor_samples do
      foreign_key :datacenter_id, :bingo_datacenters, null: false, on_delete: :cascade
      DateTime :bucket_at, null: false
      Integer  :checks, null: false, default: 0
      Integer  :ok, null: false, default: 0
      Integer  :rtt_ms_sum, null: false, default: 0
      primary_key %i[datacenter_id bucket_at]
    end

    # One row per bucket the worker ran in: its rounds (a heartbeat) and the
    # control hosts' results.
    create_table :bingo_monitor_buckets do
      DateTime :bucket_at, primary_key: true
      Integer  :rounds, null: false, default: 0
      Integer  :control_checks, null: false, default: 0
      Integer  :control_ok, null: false, default: 0
    end

    # The public site's read-only role (provisioned by the storage repo).
    if from(:pg_roles).where(rolname: 'bingo').any?
      %w[bingo_monitor_targets bingo_monitor_samples bingo_monitor_buckets].each do |t|
        run "GRANT SELECT ON #{t} TO bingo"
      end
    end
  end

  down do
    drop_table :bingo_monitor_buckets, :bingo_monitor_samples, :bingo_monitor_targets
  end
end
