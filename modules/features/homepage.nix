# modules/features/homepage.nix
{ config, lib, ... }:
let
  # Every host lugh watches, for a card each (CPU, memory, root disk, uptime from Prometheus).
  hosts = builtins.attrNames config.hosts;
  groups = [
    "Apps"
    "Media"
    "Monitoring"
    "Infrastructure"
  ];
in
{
  # The start page, home.gatica.one on lugh, behind Pocket ID: a card for every site that has a homepage entry
  # (web.sites.<name>.homepage) with a live up/down dot from its health path, the hosts from Prometheus, and Blocky's
  # day. Nothing here is set by hand in its UI; it's all this file and the sites' own entries.
  flake.modules.nixos.homepage =
    { config, ... }:
    let
      port = 8082;
      prometheus = "http://127.0.0.1:${toString config.services.prometheus.port}";
      percent = {
        type = "percent";
        options.maximumFractionDigits = 0;
      };
      metric = label: query: format: { inherit label query format; };

      sites = lib.filterAttrs (_: site: site.homepage != null) config.web.sites;
      card = name: site: {
        ${site.homepage.name} = {
          href = "https://${name}.gatica.one${site.homepage.path}";
          inherit (site.homepage) icon description;
          siteMonitor = "https://${name}.gatica.one${site.healthPath}";
        };
      };
      siteGroup =
        group:
        let
          members = lib.filterAttrs (_: site: site.homepage.group == group) sites;
        in
        lib.optional (members != { }) { ${group} = lib.mapAttrsToList card members; };

      hostCard = host: {
        ${host} = {
          icon = "nixos.png";
          description = "${host}.netbird.cloud";
          widget = {
            type = "prometheusmetric";
            url = prometheus;
            refreshInterval = 30000;
            metrics = [
              (metric "CPU" ''100 * (1 - avg(rate(node_cpu_seconds_total{host="${host}", mode="idle"}[5m])))'' percent)
              (metric "Memory" ''100 * (1 - node_memory_MemAvailable_bytes{host="${host}"} / node_memory_MemTotal_bytes{host="${host}"})'' percent)
              (metric "Disk" ''100 * (1 - node_filesystem_avail_bytes{host="${host}", mountpoint="/"} / node_filesystem_size_bytes{host="${host}", mountpoint="/"})'' percent)
              (metric "Up" ''(time() - node_boot_time_seconds{host="${host}"}) / 86400'' {
                type = "number";
                options.maximumFractionDigits = 1;
                suffix = " d";
              })
            ];
          };
        };
      };

      blocky = {
        Blocky = {
          icon = "blocky.png";
          description = "DNS for the owner's devices (lugh, nabu)";
          widget = {
            type = "prometheusmetric";
            url = prometheus;
            refreshInterval = 60000;
            metrics = [
              (metric "Queries today" "sum(increase(blocky_query_total[24h]))" {
                type = "number";
                options.maximumFractionDigits = 0;
              })
              (metric "Blocked" ''100 * sum(increase(blocky_response_total{response_type="BLOCKED"}[24h])) / sum(increase(blocky_response_total[24h]))'' percent)
              (metric "Cached" "100 * sum(rate(blocky_cache_hits_total[24h])) / (sum(rate(blocky_cache_hits_total[24h])) + sum(rate(blocky_cache_misses_total[24h])))" percent)
              (metric "Servers up" ''sum(up{job="blocky"})'' { type = "number"; })
            ];
          };
        };
      };
    in
    {
      services.homepage-dashboard = {
        enable = true;
        listenPort = port;
        allowedHosts = "home.gatica.one";
        settings = {
          title = "Cosmos";
          theme = "dark";
          color = "slate";
          headerStyle = "clean";
          hideVersion = true;
          statusStyle = "dot";
          layout = {
            Hosts = {
              style = "row";
              columns = builtins.length hosts;
            };
          }
          // lib.genAttrs groups (_: {
            style = "row";
            columns = 4;
          });
        };
        services = [
          { Hosts = map hostCard hosts; }
        ]
        ++ lib.concatMap siteGroup groups
        ++ [ { Network = [ blocky ]; } ];
        widgets = [
          {
            datetime = {
              text_size = "xl";
              format = {
                dateStyle = "long";
                timeStyle = "short";
                hour12 = false;
              };
            };
          }
        ];
      };

      web.sites.home = {
        inherit port;
        healthPath = "/api/healthcheck";
        sso = true;
      };

      # For the homelab map (modules/topology.nix).
      topology.self.services.homepage = {
        name = "Homepage";
        info = "home.gatica.one";
        details.role.text = "The start page: every site, the hosts and DNS at a glance.";
      };

      monitor = {
        units = [ "homepage-dashboard" ];
        ports.homepage = port;
      };
    };
}
