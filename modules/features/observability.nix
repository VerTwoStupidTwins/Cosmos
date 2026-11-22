# modules/features/observability.nix
let
  # The watched hosts (each imports nixos.observed). A laptop is often asleep or away, so it gets no down alerts.
  hosts = {
    lugh = { };
    nabu.nvidia = true;
    tenjin.laptop = true;
  };
  hostNames = builtins.attrNames hosts;
  laptops = builtins.filter (h: hosts.${h}.laptop or false) hostNames;
  servers = builtins.filter (h: !(hosts.${h}.laptop or false)) hostNames;
in
{
  # The homelab's watchtower, on lugh: Prometheus scrapes every host's exporters, Loki keeps their journals, Grafana
  # shows both at grafana.gatica.one, and Alertmanager pushes what needs attention to the phone through ntfy.
  flake.modules.nixos.observability =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      ports = {
        prometheus = 9090;
        alertmanager = 9093;
        alertmanagerNtfy = 8000;
        blackbox = 9115;
        loki = 3100;
        grafana = 3000;
      };

      notLaptop = ''host!~"${lib.concatStringsSep "|" laptops}"'';

      target = host: port: {
        targets = [ "${host}.netbird.cloud:${toString port}" ];
        labels.host = host;
      };
      exporter = config.services.prometheus.exporters;

      rule = name: expr: for: severity: summary: {
        alert = name;
        inherit expr for;
        labels = { inherit severity; };
        annotations.summary = summary;
      };

      # Temperatures by the chip that reports them, from node_hwmon_chip_names.
      hwmonTemp = chips: ''node_hwmon_temp_celsius * on(instance, chip) group_left(chip_name) node_hwmon_chip_names{chip_name=~"${chips}"}'';
      realFilesystems = ''fstype!~"tmpfs|devtmpfs|ramfs|squashfs|overlay|fuse.*|nsfs|efivarfs"'';
      # bcachefs mounts each subvolume of one filesystem separately; one alert per device is enough.
      diskUsed = ''max by (host, device) (100 * (1 - node_filesystem_avail_bytes{${realFilesystems}} / node_filesystem_size_bytes{${realFilesystems}}))'';

      rules = pkgs.writeText "homelab-rules.yml" (
        builtins.toJSON {
          groups = [
            {
              name = "hosts";
              rules = [
                (rule "HostDown" ''up{job="node", ${notLaptop}} == 0'' "5m" "critical"
                  "{{ $labels.host }} isn't answering"
                )
                (rule "ExporterDown" ''up{job!="node", ${notLaptop}} == 0'' "10m" "warning"
                  "{{ $labels.job }} on {{ $labels.host }} isn't answering"
                )
                (rule "SystemdUnitFailed" ''node_systemd_unit_state{state="failed"} == 1'' "2m" "warning"
                  "{{ $labels.name }} failed on {{ $labels.host }}"
                )
                (rule "MemoryLow" "node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.10" "10m" "warning"
                  "{{ $labels.host }} has under 10% of its RAM available"
                )
                (rule "DiskFilling" "${diskUsed} > 85" "15m" "warning"
                  "{{ $labels.device }} on {{ $labels.host }} is {{ $value | printf \"%.0f\" }}% full"
                )
                (rule "DiskFull" "${diskUsed} > 95" "5m" "critical"
                  "{{ $labels.device }} on {{ $labels.host }} is {{ $value | printf \"%.0f\" }}% full"
                )
                (rule "CpuHot" "${hwmonTemp "k10temp|coretemp"} > 85" "5m" "warning"
                  "The CPU on {{ $labels.host }} is at {{ $value }} °C"
                )
              ];
            }
            {
              name = "disks";
              rules = [
                (rule "SmartFailing" "smartctl_device_smart_status == 0" "0m" "critical"
                  "{{ $labels.device }} on {{ $labels.host }} reports SMART failure"
                )
                (rule "NvmeCriticalWarning" "smartctl_device_critical_warning > 0" "0m" "critical"
                  "{{ $labels.device }} on {{ $labels.host }} raised an NVMe critical warning"
                )
                (rule "NvmeWorn" "smartctl_device_percentage_used > 80" "1h" "warning"
                  "{{ $labels.device }} on {{ $labels.host }} has used {{ $value }}% of its rated life"
                )
                (rule "NvmeHot" ''smartctl_device_temperature{temperature_type="current"} > 70'' "10m" "warning"
                  "{{ $labels.device }} on {{ $labels.host }} is at {{ $value }} °C"
                )
              ];
            }
            {
              name = "gpus";
              rules = [
                # The P100s slow down at 82 °C and shut down at 85; nabu's fan holds them near 70.
                (rule "NvidiaGpuHot" "nvidia_smi_temperature_gpu > 80" "2m" "critical"
                  "{{ $labels.name }} on {{ $labels.host }} is at {{ $value }} °C"
                )
                (rule "GpuHot" "${hwmonTemp "amdgpu|xe"} > 90" "5m" "warning"
                  "A {{ $labels.chip_name }} card on {{ $labels.host }} is at {{ $value }} °C"
                )
              ];
            }
            {
              name = "probes";
              rules = [
                (rule "ProbeFailed" "probe_success == 0" "5m" "critical" "{{ $labels.instance }} isn't answering")
                (rule "CertExpiring" "probe_ssl_earliest_cert_expiry - time() < 14 * 86400" "1h" "warning"
                  "The certificate for {{ $labels.instance }} expires in under two weeks"
                )
              ];
            }
          ];
        }
      );

      blackboxConfig = pkgs.writeText "blackbox.yml" (
        builtins.toJSON {
          modules = {
            http_2xx = {
              prober = "http";
              http.preferred_ip_protocol = "ip4";
            };
            icmp = {
              prober = "icmp";
              icmp.preferred_ip_protocol = "ip4";
            };
            # A DNS server that answers grafana.gatica.one with an address (dns.nix).
            dns_gatica = {
              prober = "dns";
              dns = {
                query_name = "grafana.gatica.one";
                query_type = "A";
                preferred_ip_protocol = "ip4";
                valid_rcodes = [ "NOERROR" ];
                validate_answer_rrs.fail_if_none_matches_regexp = [ ".*\\sA\\s.*" ];
              };
            };
          };
        }
      );

      # Probes go through the blackbox exporter, which gets the target as a parameter.
      probe = module: targets: {
        job_name = "probe-${module}";
        metrics_path = "/probe";
        params.module = [ module ];
        static_configs = [ { inherit targets; } ];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            target_label = "__address__";
            replacement = "127.0.0.1:${toString ports.blackbox}";
          }
        ];
      };

      # Dashboards from grafana.com, pinned, plus those other modules add (observability.dashboards). Each chooses its
      # data source with a template variable.
      dashboards = pkgs.linkFarm "grafana-dashboards" (
        config.observability.dashboards
        ++ [
        {
          name = "node-exporter-full.json";
          path = pkgs.fetchurl {
            url = "https://grafana.com/api/dashboards/1860/revisions/46/download";
            hash = "sha256-5Y3cXcU11MkB+U2pZIvD49Wue2946Y4YW86LKJlhzqM=";
          };
        }
        {
          name = "nvidia-gpu.json";
          path = pkgs.fetchurl {
            url = "https://grafana.com/api/dashboards/14574/revisions/19/download";
            hash = "sha256-N0GyDIMaG1NW9K4gMZvQaHUqjDnEosUMaYo0mCqSGxc=";
          };
        }
        ]
      );

      secretFile = name: "$__file{${config.sops.secrets.${name}.path}}";
      hostSecrets = ../../secrets/${config.networking.hostName}.yaml;
    in
    {
      # What other modules can add to the watchtower.
      imports = [
        {
          options.observability = {
            dashboards = lib.mkOption {
              type = lib.types.listOf lib.types.attrs;
              default = [ ];
              description = "More Grafana dashboards, as linkFarm entries ({ name = \"x.json\"; path = …; }).";
            };
            dnsProbeTargets = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "DNS servers (host:port) that must answer grafana.gatica.one.";
            };
          };
        }
      ];

      services.prometheus = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = ports.prometheus;
        retentionTime = "90d";
        globalConfig.scrape_interval = "30s";
        ruleFiles = [ rules ];
        alertmanagers = [ { static_configs = [ { targets = [ "127.0.0.1:${toString ports.alertmanager}" ]; } ]; } ];
        scrapeConfigs = [
          {
            job_name = "node";
            static_configs = map (h: target h exporter.node.port) hostNames;
          }
          {
            job_name = "smartctl";
            static_configs = map (h: target h exporter.smartctl.port) hostNames;
          }
          {
            job_name = "nvidia-gpu";
            static_configs = map (h: target h exporter.nvidia-gpu.port) (
              builtins.filter (h: hosts.${h}.nvidia or false) hostNames
            );
          }
          {
            job_name = "loki";
            static_configs = [
              {
                targets = [ "127.0.0.1:${toString ports.loki}" ];
                labels.host = config.networking.hostName;
              }
            ];
          }
          # Every site behind the web gateway, at its health path: a site that stops answering, or whose
          # certificate is about to run out, raises an alert without being listed here.
          (probe "http_2xx" (
            lib.mapAttrsToList (name: site: "https://${name}.gatica.one${site.healthPath}") config.web.sites
          ))
          (probe "icmp" (map (h: "${h}.netbird.cloud") servers))
          (probe "dns_gatica" config.observability.dnsProbeTargets)
        ];

        alertmanager = {
          enable = true;
          listenAddress = "127.0.0.1";
          port = ports.alertmanager;
          configuration = {
            route = {
              receiver = "homelab";
              group_by = [
                "alertname"
                "host"
              ];
              group_wait = "30s";
              group_interval = "5m";
              repeat_interval = "4h";
            };
            receivers = [
              {
                name = "homelab";
                webhook_configs = [
                  { url = "http://127.0.0.1:${toString ports.alertmanagerNtfy}/hook"; }
                ]
                # The agent explains each new alert in its Alerts room (agent.nix); ntfy doesn't depend on it.
                ++ lib.optional (config ? agent) { url = "http://127.0.0.1:${toString config.agent.alerts.port}/alertmanager"; };
              }
            ];
          };
        };

        # Alertmanager's webhooks become ntfy messages. It talks to ntfy directly, not through nginx, so alerts don't
        # depend on DNS or the certificate.
        alertmanager-ntfy = {
          enable = true;
          settings = {
            http.addr = "127.0.0.1:${toString ports.alertmanagerNtfy}";
            ntfy = {
              baseurl = "http://127.0.0.1:${toString config.web.sites.ntfy.port}";
              notification.topic = "homelab";
            };
          };
          extraConfigFiles = [ config.sops.templates."alertmanager-ntfy.yml".path ];
        };

        exporters.blackbox = {
          enable = true;
          listenAddress = "127.0.0.1";
          port = ports.blackbox;
          configFile = blackboxConfig;
        };
      };

      sops.secrets.ntfy-alertmanager-token.sopsFile = hostSecrets;
      sops.templates."alertmanager-ntfy.yml".content = builtins.toJSON {
        ntfy.auth.token = config.sops.placeholder.ntfy-alertmanager-token;
      };

      services.loki = {
        enable = true;
        configuration = {
          auth_enabled = false;
          server = {
            http_listen_port = ports.loki;
            grpc_listen_port = 9096;
          };
          common = {
            path_prefix = config.services.loki.dataDir;
            storage.filesystem = {
              chunks_directory = "${config.services.loki.dataDir}/chunks";
              rules_directory = "${config.services.loki.dataDir}/rules";
            };
            replication_factor = 1;
            ring = {
              instance_addr = "127.0.0.1";
              kvstore.store = "inmemory";
            };
          };
          schema_config.configs = [
            {
              from = "2026-11-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];
          limits_config = {
            retention_period = "720h";
            # A laptop back from a few days away still gets its logs in.
            reject_old_samples_max_age = "168h";
          };
          compactor = {
            working_directory = "${config.services.loki.dataDir}/compactor";
            retention_enabled = true;
            delete_request_store = "filesystem";
          };
          analytics.reporting_enabled = false;
        };
      };
      # Every watched host's Alloy pushes here, through NetBird's CosmosWatched → CosmosInfra policy (modules/base/netbird.nix).
      networking.firewall.interfaces."nb-wt0".allowedTCPPorts = [ ports.loki ];

      sops.secrets = {
        grafana-admin-password = {
          sopsFile = hostSecrets;
          owner = "grafana";
        };
        grafana-secret-key = {
          sopsFile = hostSecrets;
          owner = "grafana";
        };
      };

      services.grafana = {
        enable = true;
        settings = {
          server = {
            http_addr = "127.0.0.1";
            http_port = ports.grafana;
            domain = "grafana.gatica.one";
            root_url = "https://grafana.gatica.one/";
          };
          security = {
            admin_user = "twins";
            admin_password = secretFile "grafana-admin-password";
            secret_key = secretFile "grafana-secret-key";
          };
          users.allow_sign_up = false;
          analytics = {
            reporting_enabled = false;
            check_for_updates = false;
            check_for_plugin_updates = false;
          };
        };
        provision = {
          enable = true;
          datasources.settings.datasources = [
            {
              name = "Prometheus";
              uid = "prometheus";
              type = "prometheus";
              url = "http://127.0.0.1:${toString ports.prometheus}";
              isDefault = true;
            }
            {
              name = "Loki";
              uid = "loki";
              type = "loki";
              url = "http://127.0.0.1:${toString ports.loki}";
            }
          ];
          dashboards.settings.providers = [
            {
              name = "homelab";
              options.path = dashboards;
            }
          ];
        };
      };

      web.sites.grafana = {
        healthPath = "/api/health";
        port = ports.grafana;
        websockets = true;
      };

      monitor = {
        units = [
          "prometheus"
          "alertmanager"
          "alertmanager-ntfy"
          "prometheus-blackbox-exporter"
          "loki"
          "grafana"
        ];
        ports = {
          inherit (ports)
            prometheus
            alertmanager
            loki
            grafana
            ;
          alertmanager-ntfy = ports.alertmanagerNtfy;
          blackbox = ports.blackbox;
        };
      };
    };
}
