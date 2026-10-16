{
  flake.modules.nixos."frigate-nvr" = { config, ... }: {
    services.frigate = {
      enable = true;
      hostname = config.networking.hostName;
      settings = {
        # Installation baseline: no invented streams, broker, model, or secrets.
        cameras = { };
        mqtt.enabled = false;
        detect.enabled = false;
        record.enabled = false;
        # Keep SQLite on the SSD while all media/state lives on the HDD.
        database.path = "/var/lib/frigate-db/frigate.db";
        ffmpeg.hwaccel_args = "preset-nvidia";
      };
    };

    systemd.services.frigate = {
      # Never silently fill the root SSD if the media disk is absent.
      unitConfig = {
        RequiresMountsFor = [ "/var/lib/frigate" ];
        ConditionPathIsMountPoint = "/var/lib/frigate";
      };
      serviceConfig = {
        StateDirectory = [ "frigate-db" ];
        SupplementaryGroups = [ "video" ];
      };
    };

    # Authenticated UI over NetBird only (SSH retains the shared base policy).
    # Local console/SSH tunneling also works without NetBird enrollment.
    networking.firewall.interfaces.wt0.allowedTCPPorts = [ 80 ];
  };
}
