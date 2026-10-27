_: {
  flake.modules.nixos."server-monitoring" = { pkgs, ... }: {
    services.prometheus = {
      enable = true;
      listenAddress = "127.0.0.1";
      retentionTime = "30d";
      extraFlags = [ "--storage.tsdb.retention.size=10GB" ];
      globalConfig.scrape_interval = "30s";
      exporters = {
        node = {
          enable = true;
          listenAddress = "127.0.0.1";
          enabledCollectors = [ "systemd" ];
        };
        blackbox = {
          enable = true;
          listenAddress = "127.0.0.1";
          configFile = (pkgs.formats.yaml { }).generate "blackbox.yml" {
            modules = {
              http_alive = {
                prober = "http";
                timeout = "5s";
                http = {
                  preferred_ip_protocol = "ip4";
                  # Authentication gates count as an available HTTP frontend.
                  valid_status_codes = [
                    200
                    301
                    302
                    303
                    307
                    308
                    401
                    403
                  ];
                  follow_redirects = false;
                };
              };
            };
          };
        };
      };
      scrapeConfigs = [
        {
          job_name = "prometheus";
          static_configs = [ { targets = [ "127.0.0.1:9090" ]; } ];
        }
        {
          job_name = "node";
          static_configs = [ { targets = [ "127.0.0.1:9100" ]; } ];
        }
      ];
    };
    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = 13000;
        };
        users.allow_sign_up = false;
        "auth.anonymous".enabled = false;
        analytics = {
          reporting_enabled = false;
          check_for_updates = false;
        };
      };
      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "Prometheus";
            uid = "prometheus";
            type = "prometheus";
            access = "proxy";
            url = "http://127.0.0.1:9090";
            isDefault = true;
            editable = false;
          }
        ];
      };
    };
  };
}
