# modules/features/internet.nix
{
  # The home connection, watched from lugh: latency and packet loss to the router and three public resolvers, all the
  # time (smokeping_prober, a ping a second each); which provider the house is reaching the internet through, every
  # five minutes, so a failover to the backup line shows up (and alerts); and a speed test every six hours, on the
  # main line only. Prometheus has it all, and Grafana's "Internet" dashboard shows it.
  #
  # Nothing about the connection is written here: the provider is whatever the lookup says at the time. The speed test's
  # report includes the house's address and location, which are dropped before anything is kept or logged.
  flake.modules.nixos.internet-monitor =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      proberPort = 9374;
      state = "/var/lib/internet-monitor";
      # node_exporter's textfile collector reads these on lugh (below).
      metrics = "${state}/metrics";

      # The router (the house's own network) and public resolvers run by three different companies (the internet).
      router = "10.77.10.1";
      internet = [
        "1.1.1.1"
        "8.8.8.8"
        "9.9.9.9"
      ];
      internetHosts = lib.concatStringsSep "|" (map (lib.replaceStrings [ "." ] [ "\\\\." ]) internet);

      # Writes a metrics file in one step, so the exporter never reads half of one.
      writeMetrics = ''
        publish() { # name, contents
          printf '%s\n' "$2" > "${metrics}/.$1.tmp"
          mv "${metrics}/.$1.tmp" "${metrics}/$1.prom"
        }
      '';

      provider = pkgs.writeShellApplication {
        name = "internet-provider";
        runtimeInputs = with pkgs; [
          coreutils
          curl
          gnused
          gawk
        ];
        text = ''
          ${writeMetrics}
          # "AS<number> <organisation>" for the address the house reaches the internet from.
          if org=$(curl -fsS --max-time 20 -A internet-monitor https://ipinfo.io/org) && [ -n "$org" ]; then
            org=$(printf '%s' "$org" | tr -d '"\\\n')
            # How often each provider has been seen: the most common one is the main line (for the speed test).
            touch "${state}/seen"
            awk -v org="$org" -F '\t' 'BEGIN { OFS = FS } $2 == org { $1++; found = 1 } { print } END { if (!found) print 1, org }' \
              "${state}/seen" > "${state}/seen.tmp"
            mv "${state}/seen.tmp" "${state}/seen"
            printf '%s\n' "$org" > "${state}/current"
            publish provider "# HELP internet_provider_info The provider the house reaches the internet through (1).
          # TYPE internet_provider_info gauge
          internet_provider_info{provider=\"$org\"} 1
          internet_provider_check_success 1
          internet_provider_check_timestamp_seconds $(date +%s)"
          else
            publish provider "internet_provider_check_success 0
          internet_provider_check_timestamp_seconds $(date +%s)"
          fi
        '';
      };

      speedtest = pkgs.writeShellApplication {
        name = "internet-speedtest";
        runtimeInputs = with pkgs; [
          coreutils
          jq
          gawk
          speedtest-go
        ];
        text = ''
          ${writeMetrics}
          current=$(cat "${state}/current" 2>/dev/null || true)
          main=$(sort -t "$(printf '\t')" -k1,1nr "${state}/seen" 2>/dev/null | head -1 | cut -f2- || true)
          # A full test moves a gigabyte or two; the backup line may be metered, so it's left alone.
          if [ -z "$current" ] || [ "$current" != "$main" ]; then
            echo "Not on the main line ($current); skipping the speed test."
            exit 0
          fi
          # Only the numbers are kept: the report also has the house's address and coordinates.
          if result=$(speedtest-go --json 2>/dev/null | jq -er '.servers[0] | [.dl_speed * 8, .ul_speed * 8, .latency / 1e9, .jitter / 1e9] | @tsv'); then
            read -r down up latency jitter <<<"$result"
            echo "Down $(awk -v b="$down" 'BEGIN { printf "%.0f", b / 1e6 }') Mbit/s, up $(awk -v b="$up" 'BEGIN { printf "%.0f", b / 1e6 }') Mbit/s"
            publish speedtest "# HELP internet_speedtest_download_bits_per_second From the last speed test (speedtest.net).
          # TYPE internet_speedtest_download_bits_per_second gauge
          internet_speedtest_download_bits_per_second{provider=\"$current\"} $down
          internet_speedtest_upload_bits_per_second{provider=\"$current\"} $up
          internet_speedtest_latency_seconds{provider=\"$current\"} $latency
          internet_speedtest_jitter_seconds{provider=\"$current\"} $jitter
          internet_speedtest_success 1
          internet_speedtest_timestamp_seconds $(date +%s)"
          else
            echo "The speed test failed."
            publish speedtest "internet_speedtest_success 0
          internet_speedtest_timestamp_seconds $(date +%s)"
          fi
        '';
      };

      # Packet loss over the last ten minutes, per target, from the prober's counters.
      loss =
        selector: window:
        "1 - (sum by (host) (rate(smokeping_response_duration_seconds_count${selector}[${window}])) / sum by (host) (rate(smokeping_requests_total${selector}[${window}])))";
      internetLoss = "(${loss ''{host=~"${internetHosts}"}'' "10m"})";
      medianLatency =
        selector:
        "histogram_quantile(0.5, sum by (le) (rate(smokeping_response_duration_seconds_bucket${selector}[10m])))";

      rule = name: expr: for: severity: summary: {
        alert = name;
        inherit expr for;
        labels = { inherit severity; };
        annotations.summary = summary;
      };
      rules = pkgs.writeText "internet-rules.yml" (
        builtins.toJSON {
          groups = [
            {
              name = "internet";
              rules = [
                # Delivered once the connection is back, if the phone was relying on it.
                (rule "InternetDown" "min(${internetLoss}) > 0.95" "2m" "critical"
                  "The house can't reach the internet (pings to all three public resolvers are failing)"
                )
                (rule "InternetPacketLoss" "avg(${internetLoss}) > 0.05" "10m" "warning"
                  "The internet connection is losing {{ $value | humanizePercentage }} of packets"
                )
                (rule "InternetSlow" "${medianLatency ''{host=~"${internetHosts}"}''} > 0.1" "15m" "warning"
                  "Pings to the internet are taking {{ $value | humanizeDuration }} (median)"
                )
                (rule "RouterPacketLoss" "${loss ''{host="${router}"}'' "10m"} > 0.02" "10m" "warning"
                  "lugh is losing {{ $value | humanizePercentage }} of pings to the router (the house's own network)"
                )
                # Two providers seen in the last 15 minutes: a switch to the backup line, or back.
                (rule "InternetProviderChanged"
                  "count(count by (provider) (last_over_time(internet_provider_info[15m]))) > 1"
                  "0m"
                  "warning"
                  "The house switched internet providers; now on {{ with query \"internet_provider_info\" }}{{ (first .).Labels.provider }}{{ end }}"
                )
                (rule "InternetMonitorStale" "time() - internet_provider_check_timestamp_seconds > 1800" "10m"
                  "warning"
                  "The internet provider check hasn't run in half an hour"
                )
              ];
            }
          ];
        }
      );

      datasource = {
        type = "prometheus";
        uid = "\${datasource}";
      };
      panel =
        id: title: type: gridPos: targets: extra:
        {
          inherit
            id
            title
            type
            gridPos
            datasource
            ;
          targets = lib.imap0 (
            i: t:
            {
              inherit datasource;
              refId = builtins.elemAt [ "A" "B" "C" "D" "E" ] i;
            }
            // t
          ) targets;
        }
        // extra;
      dashboard = pkgs.writeText "internet.json" (
        builtins.toJSON {
          title = "Internet";
          uid = "internet";
          tags = [ "homelab" ];
          time = {
            from = "now-24h";
            to = "now";
          };
          refresh = "1m";
          schemaVersion = 39;
          templating.list = [
            {
              name = "datasource";
              type = "datasource";
              query = "prometheus";
              label = "Data source";
            }
          ];
          panels = [
            (panel 1 "Provider" "state-timeline"
              {
                x = 0;
                y = 0;
                w = 24;
                h = 4;
              }
              [
                {
                  expr = "internet_provider_info";
                  legendFormat = "{{provider}}";
                }
              ]
              {
                options = {
                  showValue = "never";
                  mergeValues = true;
                };
              }
            )
            (panel 2 "Latency (median)" "timeseries"
              {
                x = 0;
                y = 4;
                w = 12;
                h = 9;
              }
              [
                {
                  expr = "histogram_quantile(0.5, sum by (host, le) (rate(smokeping_response_duration_seconds_bucket[5m])))";
                  legendFormat = "{{host}}";
                }
              ]
              { fieldConfig.defaults.unit = "s"; }
            )
            (panel 3 "Packet loss" "timeseries"
              {
                x = 12;
                y = 4;
                w = 12;
                h = 9;
              }
              [
                {
                  expr = loss "" "5m";
                  legendFormat = "{{host}}";
                }
              ]
              {
                fieldConfig.defaults = {
                  unit = "percentunit";
                  min = 0;
                };
              }
            )
            (panel 4 "Speed" "timeseries"
              {
                x = 0;
                y = 13;
                w = 16;
                h = 9;
              }
              [
                {
                  expr = "internet_speedtest_download_bits_per_second";
                  legendFormat = "down ({{provider}})";
                }
                {
                  expr = "internet_speedtest_upload_bits_per_second";
                  legendFormat = "up ({{provider}})";
                }
              ]
              {
                fieldConfig.defaults = {
                  unit = "bps";
                  custom = {
                    drawStyle = "line";
                    lineInterpolation = "stepAfter";
                    showPoints = "always";
                  };
                };
              }
            )
            (panel 5 "Last speed test" "stat"
              {
                x = 16;
                y = 13;
                w = 8;
                h = 9;
              }
              [
                {
                  expr = "internet_speedtest_download_bits_per_second";
                  legendFormat = "Down";
                }
                {
                  expr = "internet_speedtest_upload_bits_per_second";
                  legendFormat = "Up";
                }
              ]
              {
                fieldConfig.defaults.unit = "bps";
                options.reduceOptions.calcs = [ "lastNotNull" ];
              }
            )
          ];
        }
      );
    in
    {
      users.users.internet-monitor = {
        isSystemUser = true;
        group = "internet-monitor";
      };
      users.groups.internet-monitor = { };

      systemd.services.smokeping-prober = {
        description = "Ping the router and the internet, for Prometheus";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          # Unprivileged pings (net.ipv4.ping_group_range covers every group on NixOS).
          ExecStart = "${lib.getExe' pkgs.prometheus-smokeping-prober "smokeping_prober"} --no-privileged --web.listen-address=127.0.0.1:${toString proberPort} ${router} ${lib.concatStringsSep " " internet}";
          DynamicUser = true;
          Restart = "always";
          RestartSec = 10;
        };
      };

      systemd.services.internet-provider = {
        description = "Note which provider the house reaches the internet through";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "internet-monitor";
          Group = "internet-monitor";
          ExecStart = lib.getExe provider;
        };
      };
      systemd.timers.internet-provider = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1m";
          OnUnitActiveSec = "5m";
        };
      };

      systemd.services.internet-speedtest = {
        description = "Test the internet connection's speed";
        after = [
          "network-online.target"
          "internet-provider.service"
        ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "internet-monitor";
          Group = "internet-monitor";
          ExecStart = lib.getExe speedtest;
          # A slow line can take a while, but never this long.
          TimeoutStartSec = "5m";
        };
      };
      systemd.timers.internet-speedtest = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "00/6:00";
          RandomizedDelaySec = "30m";
          Persistent = true;
        };
      };

      # The state directory, readable by node_exporter for the metrics files.
      systemd.tmpfiles.settings.internet-monitor = {
        ${state}.d = {
          user = "internet-monitor";
          group = "internet-monitor";
          mode = "0755";
        };
        ${metrics}.d = {
          user = "internet-monitor";
          group = "internet-monitor";
          mode = "0755";
        };
      };
      services.prometheus.exporters.node.extraFlags = [ "--collector.textfile.directory=${metrics}" ];

      services.prometheus = {
        ruleFiles = [ rules ];
        scrapeConfigs = [
          {
            job_name = "smokeping";
            # Every second's pings, summarised: a 30s scrape loses nothing.
            static_configs = [
              {
                targets = [ "127.0.0.1:${toString proberPort}" ];
                labels.instance = config.networking.hostName;
              }
            ];
          }
        ];
      };

      observability.dashboards = [
        {
          name = "internet.json";
          path = dashboard;
        }
      ];

      monitor.units = [ "smokeping-prober" ];
    };
}
