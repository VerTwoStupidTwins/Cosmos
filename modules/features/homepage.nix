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
      themeDir = "/var/lib/home-theme";
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

      # What each host is for, on its card (instead of its address).
      roles = {
        lugh = "Infrastructure server";
        nabu = "LLM server";
        tenjin = "Workstation";
      };
      hostCard = host: {
        ${host} = {
          icon = "nixos.png";
          description = roles.${host} or "";
          widget = {
            type = "prometheusmetric";
            url = prometheus;
            refreshInterval = 30000;
            metrics = [
              (metric "CPU" ''100 * (1 - avg(rate(node_cpu_seconds_total{host="${host}", mode="idle"}[5m])))''
                percent
              )
              (metric "Memory"
                ''100 * (1 - node_memory_MemAvailable_bytes{host="${host}"} / node_memory_MemTotal_bytes{host="${host}"})''
                percent
              )
              (metric "Disk"
                ''100 * (1 - node_filesystem_avail_bytes{host="${host}", mountpoint="/"} / node_filesystem_size_bytes{host="${host}", mountpoint="/"})''
                percent
              )
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
              (metric "Blocked"
                ''100 * sum(increase(blocky_response_total{response_type="BLOCKED"}[24h])) / sum(increase(blocky_response_total[24h]))''
                percent
              )
              (metric "Cached"
                "100 * sum(rate(blocky_cache_hits_total[24h])) / (sum(rate(blocky_cache_hits_total[24h])) + sum(rate(blocky_cache_misses_total[24h])))"
                percent
              )
              (metric "Servers up" ''sum(up{job="blocky"})'' { type = "number"; })
            ];
          };
        };
      };

      # Which provider the house is going out through, from lugh's internet monitor (internet.nix), with the AS
      # number trimmed off. prometheusmetric only shows values, so this reads the label through Prometheus's API.
      internet = {
        Internet = {
          icon = "mdi-web";
          href = "https://grafana.gatica.one/d/internet";
          description = "Checked every 5 minutes";
          widget = {
            type = "customapi";
            # label_replace(internet_provider_info, "provider", "$1", "provider", "AS[0-9]+ (.+)"), URL-encoded.
            url = "${prometheus}/api/v1/query?query=label_replace(internet_provider_info%2C%22provider%22%2C%22%241%22%2C%22provider%22%2C%22AS%5B0-9%5D%2B%20(.%2B)%22)";
            refreshInterval = 60000;
            mappings = [
              {
                label = "ISP";
                field = "data.result.0.metric.provider";
              }
            ];
          };
        };
      };

      # Alerts firing now and not silenced, from Alertmanager: one line each, its summary and severity.
      alerts = {
        "Firing alerts" = {
          icon = "alertmanager.png";
          href = "https://alertmanager.gatica.one";
          description = "Firing, not silenced";
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

      # The tabs, in order, and the groups on each, in order (services and bookmark groups alike), each with its
      # layout. Homepage keeps a list's order; an attrset would come out alphabetical. A group on no tab would show
      # on every tab. A row spans the page in that many columns; the bookmark groups sit side by side, as icons.
      row = name: columns: {
        inherit name;
        layout = {
          style = "row";
          inherit columns;
        };
      };
      side = name: {
        inherit name;
        layout.iconsOnly = true;
      };
      tabs = [
        {
          name = "Home";
          groups = [
            (row "Systems" (builtins.length hosts + 1))
            (row "Apps" 3)
            (side "Cosmos")
            (side "Nix")
          ];
        }
        {
          name = "Monitoring";
          groups = [
            (row "Monitoring" 4)
            (row "Network" 4)
          ];
        }
        {
          name = "Infrastructure";
          groups = [ (row "Infrastructure" 4) ];
        }
      ];
      tabGroups = lib.concatMap (tab: map (group: group.name) tab.groups) tabs;

      # The desktop's palette (tenjin puts it at /theme.css, home-theme.nix) mapped onto Homepage's ten-step
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
        logo-stop = "base03";
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
          quicklaunch = {
            searchDescriptions = true;
            showSearchSuggestions = true;
            provider = "duckduckgo";
          };
          layout = lib.concatMap (
            tab:
            map (group: {
              ${group.name} = group.layout // {
                tab = tab.name;
              };
            }) tab.groups
          ) tabs;
        };
        services =
          let
            sited = lib.mergeAttrsList (lib.concatMap siteGroup groups);
            all = sited // {
              # The hosts, and alongside them anything firing.
              Systems = map hostCard hosts ++ [ alerts ];
              # Media joins the apps on Home: one row, not two half-empty ones.
              Apps = (sited.Apps or [ ]) ++ (sited.Media or [ ]);
              Network = [
                internet
                blocky
              ];
            };
          in
          lib.concatMap (name: lib.optional (all ? ${name}) { ${name} = all.${name}; }) tabGroups;
        bookmarks = [
          {
            Cosmos = [
              {
                "Cosmos repo" = [
                  {
                    icon = "si-github";
                    href = "https://github.com/VerTwoStupidTwins/Cosmos";
                  }
                ];
              }
              {
                NetBird = [
                  {
                    icon = "netbird.png";
                    href = "https://app.netbird.io";
                  }
                ];
              }
              {
                Spaceship = [
                  {
                    icon = "mdi-dns";
                    href = "https://www.spaceship.com/application/advanced-dns-application/manage/gatica.one";
                  }
                ];
              }
            ];
          }
          {
            Nix = [
              {
                Packages = [
                  {
                    icon = "nixos.png";
                    href = "https://search.nixos.org/packages?channel=unstable";
                  }
                ];
              }
              {
                Options = [
                  {
                    icon = "nixos.png";
                    href = "https://search.nixos.org/options?channel=unstable";
                  }
                ];
              }
              {
                "Home Manager" = [
                  {
                    icon = "mdi-home-outline";
                    href = "https://home-manager-options.extranix.com";
                  }
                ];
              }
              {
                Noogle = [
                  {
                    icon = "mdi-function-variant";
                    href = "https://noogle.dev";
                  }
                ];
              }
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
              # Minutes. Homepage caches a failed answer as long as a good one, so keep it short.
              cache = 5;
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
          @import url("/theme.css");

          html.theme-slate, .theme-slate {
          ${
            lib.concatStrings (
              lib.mapAttrsToList (step: key: "  --color-${step}: var(--${key}-rgb, ${slate.${step}});\n") scale
            )
          }}

          ${builtins.readFile ./homepage.css}
        '';
      };

      web.sites.home = {
        inherit port;
        healthPath = "/api/healthcheck";
        sso = true;
      };

      # The desktop's palette as CSS variables, put here by tenjin (modules/desktop/home-theme.nix) whenever the
      # wallpaper changes, and served to every browser. Reading it needs no sign-in (it's colours only); writing it
      # needs the theme token, checked in an include that sops renders at runtime, so the token never reaches the store.
      sops.secrets.chat-theme-token.sopsFile = ../../secrets/common.yaml;
      sops.templates."home-theme-auth.conf" = {
        owner = "nginx";
        content = ''
          if ($http_authorization != "Bearer ${config.sops.placeholder.chat-theme-token}") {
            set $theme_write "''${theme_write}-unauthorised";
          }
        '';
        restartUnits = [ "nginx.service" ];
      };
      systemd.tmpfiles.rules = [ "d ${themeDir} 0755 nginx nginx - -" ];
      systemd.services.nginx.serviceConfig.ReadWritePaths = [ themeDir ];
      services.nginx.virtualHosts."home.gatica.one".locations."= /theme.css".extraConfig = ''
        auth_request off;
        root ${themeDir};
        default_type text/css;
        add_header Cache-Control "no-cache" always;
        dav_methods PUT;
        client_max_body_size 16k;
        set $theme_write $request_method;
        include ${config.sops.templates."home-theme-auth.conf".path};
        # 403, not 401: the site turns a 401 into a redirect to the sign-in page, which curl would take as success.
        if ($theme_write = "PUT-unauthorised") {
          return 403;
        }
      '';

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
