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

      # Alerts firing now and not silenced, from Alertmanager: one line each, its summary and severity.
      alerts = {
        "Firing alerts" = {
          icon = "alertmanager.png";
          href = "https://alertmanager.gatica.one";
          description = "Firing now, not silenced";
          widget = {
            type = "customapi";
            url = "http://127.0.0.1:${toString config.services.prometheus.alertmanager.port}/api/v2/alerts?active=true&silenced=false&inhibited=false";
            refreshInterval = 30000;
            display = "dynamic-list";
            mappings = {
              name = "annotations.summary";
              label = "labels.severity";
              target = "https://alertmanager.gatica.one/#/alerts";
            };
          };
        };
      };

      # The tabs, in order, and the groups on each, in order (services and bookmark groups alike). Homepage keeps a
      # list's order; an attrset would come out alphabetical. A group on no tab would show on every tab.
      tabs = [
        {
          name = "Home";
          groups = [
            "Alerts"
            "Hosts"
            "Apps"
            "Media"
            "Cosmos"
            "Nix"
          ];
        }
        {
          name = "Monitoring";
          groups = [
            "Monitoring"
            "Network"
          ];
        }
        {
          name = "Infrastructure";
          groups = [ "Infrastructure" ];
        }
      ];
      tabGroups = lib.concatMap (tab: tab.groups) tabs;

      # The desktop's palette (tenjin pushes it to the chat site, chat-theme.nix) mapped onto Homepage's ten-step
      # scale, so the page recolours with the wallpaper. Before any palette arrives, Homepage's slate applies.
      scale = {
        "50" = "base07";
        "100" = "base07";
        "200" = "base06";
        "300" = "base05";
        "400" = "base04";
        "500" = "base04";
        "600" = "base03";
        "700" = "base02";
        "800" = "base01";
        "900" = "base00";
        logo-start = "accent";
        logo-stop = "base01";
      };
      slate = {
        "50" = "248 250 252";
        "100" = "241 245 249";
        "200" = "226 232 240";
        "300" = "203 213 225";
        "400" = "148 163 184";
        "500" = "100 116 139";
        "600" = "71 85 105";
        "700" = "51 65 85";
        "800" = "30 41 59";
        "900" = "15 23 42";
        logo-start = "148 163 184";
        logo-stop = "51 65 85";
      };
    in
    {
      # HOMEPAGE_VAR_WEATHER_{LABEL,LATITUDE,LONGITUDE}: the weather's place, kept out of the repo.
      sops.secrets.homepage-env.sopsFile = ../../secrets/${config.networking.hostName}.yaml;

      services.homepage-dashboard = {
        enable = true;
        listenPort = port;
        environmentFiles = [ config.sops.secrets.homepage-env.path ];
        allowedHosts = "home.gatica.one";
        settings = {
          title = "Cosmos";
          theme = "dark";
          color = "slate";
          headerStyle = "clean";
          hideVersion = true;
          statusStyle = "dot";
          # The wallpaper, blurred and dimmed, behind frosted cards. tenjin pushes it with the palette; it's
          # revalidated on every load, so a new wallpaper shows on the next one.
          background = {
            image = "https://chat.gatica.one/wallpaper.jpg";
            blur = "md";
            saturate = 100;
            brightness = 50;
          };
          cardBlur = "md";
          quicklaunch = {
            searchDescriptions = true;
            showSearchSuggestions = true;
            provider = "duckduckgo";
          };
          layout = lib.concatMap (
            tab:
            map (name: {
              ${name} = {
                tab = tab.name;
                style = "row";
                columns = if name == "Hosts" then builtins.length hosts else 4;
              };
            }) tab.groups
          ) tabs;
        };
        services =
          let
            all = {
              Alerts = [ alerts ];
              Hosts = map hostCard hosts;
              Network = [ blocky ];
            }
            // lib.mergeAttrsList (lib.concatMap siteGroup groups);
          in
          lib.concatMap (name: lib.optional (all ? ${name}) { ${name} = all.${name}; }) tabGroups;
        bookmarks = [
          {
            Cosmos = [
              { "Cosmos repo" = [ { icon = "github.png"; href = "https://github.com/VerTwoStupidTwins/Cosmos"; } ]; }
              { NetBird = [ { icon = "netbird.png"; href = "https://app.netbird.io"; } ]; }
              { Spaceship = [ { abbr = "SP"; href = "https://www.spaceship.com/application/advanced-dns-application/manage/gatica.one"; } ]; }
            ];
          }
          {
            Nix = [
              { "NixOS packages" = [ { icon = "nixos.png"; href = "https://search.nixos.org/packages?channel=unstable"; } ]; }
              { "NixOS options" = [ { icon = "nixos.png"; href = "https://search.nixos.org/options?channel=unstable"; } ]; }
              { "Home Manager options" = [ { abbr = "HM"; href = "https://home-manager-options.extranix.com"; } ]; }
              { Noogle = [ { abbr = "NG"; href = "https://noogle.dev"; } ]; }
            ];
          }
        ];
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
          # Where the owner lives stays out of this public repo: the place and its coordinates come from the
          # homepage-env secret, which Homepage substitutes for these placeholders. Open-Meteo, no key.
          {
            openmeteo = {
              label = "{{HOMEPAGE_VAR_WEATHER_LABEL}}";
              latitude = "{{HOMEPAGE_VAR_WEATHER_LATITUDE}}";
              longitude = "{{HOMEPAGE_VAR_WEATHER_LONGITUDE}}";
              timezone = "America/Los_Angeles";
              units = "imperial";
              cache = 15;
            };
          }
          {
            search = {
              provider = "duckduckgo";
              target = "_blank";
              showSearchSuggestions = true;
            };
          }
        ];
        customCSS = ''
          @import url("https://chat.gatica.one/theme.css");

          html.theme-slate, .theme-slate {
          ${lib.concatStrings (
            lib.mapAttrsToList (
              step: key: "  --color-${step}: var(--${key}-rgb, ${slate.${step}});\n"
            ) scale
          )}}

          ::selection {
            background: rgb(var(--accent-rgb, 148 163 184) / 0.5);
          }
        '';
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
