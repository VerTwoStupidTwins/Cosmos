{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  flake.modules.nixos.odin = { pkgs, ... }: {
    imports = [
      nixos.homarr
      nixos."server-monitoring"
    ];
    users.users.homarr.uid = 990;
    virtualisation.oci-containers.containers.homarr.environment.BASE_URL = "http://100.94.82.252:7575";
    # New machine-local secrets are generated once on activation and never rotated here.
    systemd.services = {
      dashboard-credentials = {
        before = [
          "grafana.service"
          "podman-homarr.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          StateDirectory = "cosmos-dashboard-credentials";
          StateDirectoryMode = "0700";
          UMask = "0077";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          NoNewPrivileges = true;
        };
        script = ''
          set -eu
          cd /var/lib/cosmos-dashboard-credentials
          if [ ! -e homarr.env ]; then
            key=$(${pkgs.openssl}/bin/openssl rand -hex 32)
            printf 'SECRET_ENCRYPTION_KEY=%s\n' "$key" > homarr.env.tmp
            mv homarr.env.tmp homarr.env
          fi
          if [ ! -e grafana-admin-password ]; then
            ${pkgs.openssl}/bin/openssl rand -hex 32 > grafana-admin-password.tmp
            mv grafana-admin-password.tmp grafana-admin-password
          fi
          test -s homarr.env
          test -s grafana-admin-password
          if [ ! -e grafana-secret-key ]; then
            ${pkgs.openssl}/bin/openssl rand -hex 32 > grafana-secret-key.tmp
            mv grafana-secret-key.tmp grafana-secret-key
          fi
          test -s grafana-secret-key
        '';
      };
      grafana = {
        requires = [ "dashboard-credentials.service" ];
        after = [ "dashboard-credentials.service" ];
        serviceConfig.LoadCredential = [
          "admin-password:/var/lib/cosmos-dashboard-credentials/grafana-admin-password"
          "secret-key:/var/lib/cosmos-dashboard-credentials/grafana-secret-key"
        ];
      };
      podman-homarr = {
        requires = [ "dashboard-credentials.service" ];
        after = [ "dashboard-credentials.service" ];
        serviceConfig.EnvironmentFile = [ "/var/lib/cosmos-dashboard-credentials/homarr.env" ];
      };
    };
    networking.firewall.interfaces.wt0.allowedTCPPorts = [
      7575
      3000
    ];
    services = {
      grafana = {
        settings = {
          server.root_url = "http://100.94.82.252:3000/";
          security = {
            admin_password = "$__file{/run/credentials/grafana.service/admin-password}";
            secret_key = "$__file{/run/credentials/grafana.service/secret-key}";
          };
        };
        provision.dashboards.settings.providers = [
          {
            name = "Cosmos";
            options.path = ../../packages/grafana-dashboards;
            disableDeletion = true;
            allowUiUpdates = false;
          }
        ];
      };
      nginx = {
        enable = true;
        recommendedProxySettings = true;
        virtualHosts = {
          homarr = {
            listen = [
              {
                addr = "0.0.0.0";
                port = 7575;
              }
            ];
            locations."/" = {
              proxyPass = "http://127.0.0.1:17575";
              proxyWebsockets = true;
            };
          };
          grafana = {
            listen = [
              {
                addr = "0.0.0.0";
                port = 3000;
              }
            ];
            locations."/" = {
              proxyPass = "http://127.0.0.1:13000";
              proxyWebsockets = true;
            };
          };
        };
      };
      prometheus.scrapeConfigs = [
        {
          job_name = "http-frontends";
          metrics_path = "/probe";
          params.module = [ "http_alive" ];
          static_configs = [
            {
              targets = [ "http://127.0.0.1:7575/" ];
              labels.service = "homarr";
            }
            {
              targets = [ "http://127.0.0.1:3000/api/health" ];
              labels.service = "grafana";
            }
            {
              targets = [ "http://100.94.82.252:9119/" ];
              labels.service = "hermes";
            }
            {
              targets = [ "http://127.0.0.1:9120/healthz" ];
              labels.service = "openconcho";
            }
            {
              targets = [ "http://127.0.0.1:8081/" ];
              labels.service = "llama-swap";
            }
          ];
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
              replacement = "127.0.0.1:9115";
            }
          ];
        }
      ];
    };
  };
  perSystem = { pkgs, ... }: {
    packages.homarr-image = pkgs.callPackage ../../packages/homarr-image.nix { };
    checks.odin-dashboard = import ../../tests/odin-dashboard.nix {
      inherit pkgs;
      odin = config.flake.nixosConfigurations.odin.config;
      thoth = config.flake.nixosConfigurations.thoth.config;
      argus = config.flake.nixosConfigurations.argus.config;
    };
  };
}
