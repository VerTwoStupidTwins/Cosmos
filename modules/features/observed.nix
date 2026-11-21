# modules/features/observed.nix
let
  # lugh collects everything (observability.nix).
  collector = "lugh.netbird.cloud";
in
{
  # What every watched host runs for lugh: Prometheus exporters for its system, disks and (on nabu) NVIDIA cards, and
  # Alloy sending its journal to Loki. NetBird's CosmosInfra → CosmosWatched policy lets only lugh reach the exporters
  # (modules/base/netbird.nix).
  flake.modules.nixos.observed =
    { config, lib, ... }:
    let
      cfg = config.observed;
      exporters = config.services.prometheus.exporters;
      ports = [
        exporters.node.port
        exporters.smartctl.port
      ]
      ++ lib.optional cfg.nvidia exporters.nvidia-gpu.port;
    in
    {
      options.observed.nvidia = lib.mkEnableOption "the NVIDIA GPU exporter, for hosts with NVIDIA cards";

      config = {
        services.prometheus.exporters = {
          node = {
            enable = true;
            # systemd: failed units for the alerts. hwmon (on by default) covers AMD and Intel GPU temperatures and power.
            enabledCollectors = [ "systemd" ];
          };
          smartctl.enable = true;
          nvidia-gpu.enable = cfg.nvidia;
        };

        networking.firewall.interfaces."nb-wt0".allowedTCPPorts = ports;

        services.alloy.enable = true;
        environment.etc."alloy/config.alloy".text = ''
          // The journal, by unit and level, to Loki on ${collector}. Alloy keeps its place in the journal, so a host
          // that was asleep or off the mesh sends what it missed when it's back, up to a day old.
          loki.relabel "journal" {
            forward_to = []

            rule {
              source_labels = ["__journal__systemd_unit"]
              target_label  = "unit"
            }
            rule {
              source_labels = ["__journal_priority_keyword"]
              target_label  = "level"
            }
            rule {
              source_labels = ["__journal_syslog_identifier"]
              target_label  = "identifier"
            }
          }

          loki.source.journal "journal" {
            max_age       = "24h"
            relabel_rules = loki.relabel.journal.rules
            labels        = { host = "${config.networking.hostName}" }
            forward_to    = [loki.write.lugh.receiver]
          }

          loki.write "lugh" {
            endpoint {
              url = "http://${collector}:3100/loki/api/v1/push"
            }
          }
        '';

        monitor = {
          units = [
            "prometheus-node-exporter"
            "prometheus-smartctl-exporter"
            "alloy"
          ]
          ++ lib.optional cfg.nvidia "prometheus-nvidia-gpu-exporter";
          ports = {
            node-exporter = exporters.node.port;
            smartctl-exporter = exporters.smartctl.port;
          }
          // lib.optionalAttrs cfg.nvidia { nvidia-gpu-exporter = exporters.nvidia-gpu.port; };
        };
      };
    };
}
