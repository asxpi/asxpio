# services.asxpio: the site, invoices and admin (Puma on a port, for a
# proxy, Traefik on asxpio-ops, to route asxp.io and admin.asxp.io to), and
# the reachability worker for datacenterbingo's status page.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.asxpio;
  inherit (lib) mkOption types;
  hardening = {
    DynamicUser = true;
    Restart = "always";
    RestartSec = 5;
    # The database may be down for a while; keep trying
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    SystemCallFilter = [ "@system-service" ];
    LockPersonality = true;
    EnvironmentFile = cfg.environmentFile;
  };
in
{
  options.services.asxpio = {
    enable = lib.mkEnableOption "asxp.io";
    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "the asxpio flake's package";
    };
    port = mkOption {
      type = types.port;
      default = 3001;
    };
    threads = mkOption {
      type = types.str;
      default = "4:16";
      description = "Puma's -t min:max.";
    };
    environmentFile = mkOption {
      type = types.str;
      description = "The app's settings and secrets (see .env.example).";
    };
    monitor.enable = mkOption {
      type = types.bool;
      default = true;
      description = "The reachability worker (bin/monitor). Run one only: two record every sample twice.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.asxpio = {
      description = "asxp.io";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      startLimitIntervalSec = 0;
      # Puma tells systemd when it listens; migrations run before that
      serviceConfig = hardening // {
        Type = "notify";
        ExecStart = "${lib.getExe cfg.package} -b tcp://0.0.0.0:${toString cfg.port} -t ${cfg.threads}";
        TimeoutStartSec = 120;
        MemoryMax = "512M";
      };
    };
    systemd.services.asxpio-monitor = lib.mkIf cfg.monitor.enable {
      description = "asxpio reachability worker";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "asxpio.service"
      ];
      wants = [ "network-online.target" ];
      startLimitIntervalSec = 0;
      environment.MONITOR_HEARTBEAT = "/tmp/monitor.heartbeat";
      serviceConfig = hardening // {
        ExecStart = "${cfg.package}/bin/asxpio-monitor";
        MemoryMax = "256M";
      };
    };
  };
}
