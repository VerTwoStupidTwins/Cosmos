# Upstream OpenConcho in rootless Podman, with ordinary nginx authentication.
{ config, ... }:
{
  flake.modules.nixos.openconcho =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.openconcho;
      image = pkgs.callPackage ../../../packages/openconcho-image.nix { };
      nginx = pkgs.callPackage ../../../packages/openconcho-nginx.nix {
        inherit (cfg) listenAddress port;
      };
      browserConfig = pkgs.writeText "openconcho-config.js" ''
        window.__OPENCONCHO_DEFAULT_HONCHO_URL__ = "http://127.0.0.1:8000";
      '';
      egress = pkgs.writeText "cosmos-openconcho-egress.nft" ''
        destroy table inet cosmos_openconcho
        table inet cosmos_openconcho {
          chain output {
            type filter hook output priority -5; policy accept;
            meta skuid "openconcho" ct direction reply ct state established,related accept
            # Same kernel WireGuard socket-UID handling as the Hermes dashboard.
            meta skuid "openconcho" meta nfproto ipv4 meta mark 0x1bd00 oifname "${cfg.transportInterface}" fib daddr type != local udp sport ${
              toString config.services.netbird.clients.${cfg.interfaceName}.port
            } counter accept
            meta skuid "openconcho" ip daddr 127.0.0.1 tcp dport { 8000, ${toString cfg.port} } accept
            meta skuid "openconcho" counter reject
          }
        }
      '';
    in
    {
      options.services.openconcho = {
        listenAddress = lib.mkOption {
          type = lib.types.strMatching "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+";
          description = "NetBird IPv4 address for the authenticated web UI.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 9120;
        };
        interfaceName = lib.mkOption {
          type = lib.types.str;
          default = "wt0";
        };
        transportInterface = lib.mkOption {
          type = lib.types.strMatching "[A-Za-z0-9_.:-]+";
          description = "Physical interface carrying the marked NetBird transport.";
        };
      };
      config = {
        system.extraDependencies = [ image ];
        users.groups.openconcho = { };
        users.users.openconcho = {
          isSystemUser = true;
          group = "openconcho";
          home = "/var/lib/openconcho";
          homeMode = "0700";
          createHome = true;
          autoSubUidGidRange = true;
          linger = true;
        };
        networking.firewall.interfaces.${cfg.interfaceName}.allowedTCPPorts = [ cfg.port ];
        virtualisation.oci-containers = {
          backend = "podman";
          containers.openconcho = {
            image = "${image.imageName}:${image.imageTag}";
            imageFile = image;
            pull = "never";
            podman.user = "openconcho";
            user = "101:101";
            networks = [ "host" ];
            entrypoint = "/bin/sh";
            cmd = [ "/opt/cosmos-start.sh" ];
            volumes = [
              "${../../../packages/openconcho-start.sh}:/opt/cosmos-start.sh:ro"
              "${nginx}:/opt/cosmos-nginx.conf:ro"
              "${browserConfig}:/opt/cosmos-config.js:ro"
            ];
            log-driver = "k8s-file";
            extraOptions = [
              "--env=OPENCONCHO_API_TOKEN"
              "--env=OPENCONCHO_HTPASSWD"
              "--userns=keep-id:uid=101,gid=101"
              "--read-only"
              "--security-opt=no-new-privileges"
              "--cap-drop=ALL"
              "--pids-limit=128"
              "--memory=512m"
              "--http-proxy=false"
              "--tmpfs=/tmp:rw,nosuid,nodev,mode=1777"
              "--log-opt=max-size=10mb"
            ];
          };
        };
        systemd.services = {
          openconcho-credentials = {
            description = "Provision private OpenConcho login and backend admin token";
            after = [ "honcho-credentials.service" ];
            requires = [ "honcho-credentials.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = "root";
              StateDirectory = "cosmos-openconcho";
              StateDirectoryMode = "0700";
              UMask = "0077";
              ExecStart = "${pkgs.python3}/bin/python3 ${../../../packages/openconcho-credentials.py} --state-dir /var/lib/cosmos-openconcho --signing-key /var/lib/cosmos-honcho/signing.key --core ${../../../packages/honcho-credentials.py} --htpasswd ${pkgs.apacheHttpd}/bin/htpasswd";
              NoNewPrivileges = true;
              PrivateTmp = true;
              PrivateDevices = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              CapabilityBoundingSet = [ ];
              RestrictAddressFamilies = [ "AF_UNIX" ];
            };
          };
          cosmos-openconcho-egress = {
            description = "Keep OpenConcho networking on the local Honcho API and NetBird replies";
            after = [ "users-groups.service" ];
            before = [ "podman-openconcho.service" ];
            serviceConfig = import ../../../packages/agent-egress-service.nix {
              inherit pkgs;
              rules = egress;
            };
          };
          podman-openconcho = {
            after = [
              "openconcho-credentials.service"
              "cosmos-openconcho-egress.service"
              "podman-honcho-api.service"
              "netbird-${cfg.interfaceName}.service"
            ];
            requires = [
              "openconcho-credentials.service"
              "cosmos-openconcho-egress.service"
            ];
            wants = [
              "podman-honcho-api.service"
              "netbird-${cfg.interfaceName}.service"
            ];
            environment.XDG_RUNTIME_DIR = "/run/user/${toString config.users.users.openconcho.uid}";
            serviceConfig = {
              EnvironmentFile = [ "/var/lib/cosmos-openconcho/container.env" ];
              ExecStartPost = [
                "${pkgs.curl}/bin/curl --fail --silent --output /dev/null --retry 20 --retry-connrefused --retry-delay 1 --max-time 2 http://127.0.0.1:${toString cfg.port}/healthz"
              ];
              ProtectSystem = "full";
              ProtectHome = false;
              InaccessiblePaths = [
                "/home"
                "/root"
                "-/run/secrets"
                "-/var/lib/hermes"
                "/var/lib/honcho"
                "/var/lib/cosmos-honcho"
                "/var/lib/cosmos-openconcho"
              ];
              UMask = "0077";
            };
          };
        };
      };
    };
  perSystem = { pkgs, ... }: {
    packages.openconcho-image = pkgs.callPackage ../../../packages/openconcho-image.nix { };
    checks.openconcho = import ../../../tests/openconcho.nix {
      inherit pkgs;
      odin = config.flake.nixosConfigurations.odin.config;
      thoth = config.flake.nixosConfigurations.thoth.config;
      argus = config.flake.nixosConfigurations.argus.config;
    };
  };
}
