# Odin's fresh local agent. No workstation state or operator identities are imported.
{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  flake.modules.nixos.odin =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    let
      inferenceGateway = pkgs.writeShellScript "cosmos-hermes-inference" ''
        exec ${pkgs.python3}/bin/python3 ${../../packages/hermes-inference-gateway.py} --port 18090
      '';
      egressRules = pkgs.writeText "cosmos-hermes-egress.nft" ''
        destroy table inet cosmos_hermes
        table inet cosmos_hermes {
          chain output {
            type filter hook output priority -5; policy accept;
            meta skuid "hermes" ct direction reply ct state established,related accept
            # Kernel WireGuard preserves the application socket UID on outer UDP.
            # Only its privileged control-plane mark and declared transport pass.
            meta skuid "hermes" meta nfproto ipv4 meta mark 0x1bd00 oifname "enp4s0" fib daddr type != local udp sport ${toString config.services.netbird.clients.wt0.port} counter accept
            meta skuid "hermes" ip daddr 127.0.0.1 tcp dport { 18090, 18092${
              lib.optionalString (
                (config.services.hermes-agent.settings.memory.provider or "") == "honcho"
              ) ", 8000"
            } } accept
            # The dashboard PTY's authenticated WS callback targets this host.
            meta skuid "hermes" meta nfproto ipv4 fib daddr type local tcp dport 9119 accept
            # Resolve through the host stub; no arbitrary external DNS access.
            meta skuid "hermes" ip daddr 127.0.0.53 udp dport 53 accept
            meta skuid "hermes" ip daddr 127.0.0.53 tcp dport 53 accept
            # Cloud APIs and Telegram/Discord use public HTTPS/WebSockets.
            # Retain the explicit local exceptions above, including Honcho.
            meta skuid "hermes" fib daddr type local counter reject
            meta skuid "hermes" ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.88.99.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4 } counter reject
            meta skuid "hermes" meta nfproto ipv4 tcp dport 443 accept
            meta skuid "hermes" counter reject
          }
        }
      '';
      hardening = {
        # Host-specific additions to hermes-local's shared process sandbox.
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        LockPersonality = true;
        InaccessiblePaths = [
          "/run/secrets"
          "/etc/ssh"
        ];
        ReadOnlyPaths = [ "/Cosmos" ];
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          # The interface-bound dashboard launcher must query wt0 with ip.
          # No network-admin capabilities are granted by allowing this family.
          "AF_NETLINK"
        ];
        TasksMax = 256;
        MemoryMax = "8G";
      };
    in
    {
      imports = [
        nixos."hermes-local"
        nixos."hermes-honcho"
      ];
      services.hermes-agent = {
        backend = {
          mode = "dashboard";
          waitFor = "interface";
          interfaceName = "wt0";
          port = 9119;
          sessionTokenFile = null;
        };
        environmentFiles = [ config.sops.secrets.hermes-dashboard-env.path ];
        # Native queue clients bootstrap over Unix, then use this fixed local WS API.
        environment.HERMES_LOCAL_OWNER_PORT = "18092";
      };
      sops.secrets.hermes-dashboard-env = {
        key = "hermes_dashboard_env";
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [
          "hermes-agent.service"
          "hermes-backend.service"
        ];
      };
      networking.firewall.interfaces.wt0.allowedTCPPorts = [ 9119 ];
      # A privileged Nix builder would otherwise be a same-host network proxy.
      nix.settings.allowed-users = [
        "root"
        "@wheel"
      ];
      users.users.hermes.extraGroups = [ "systemd-journal" ];
      systemd.services = {
        cosmos-hermes-egress = {
          description = "UID-wide Hermes egress boundary (also covers detached workers)";
          wantedBy = [
            "multi-user.target"
            "network-pre.target"
          ];
          before = [
            "network-pre.target"
            "hermes-agent.service"
            "hermes-backend.service"
            "shutdown.target"
          ];
          after = [ "local-fs.target" ];
          conflicts = [ "shutdown.target" ];
          unitConfig.DefaultDependencies = false;
          serviceConfig =
            (import ../../packages/agent-egress-service.nix {
              inherit pkgs;
              rules = egressRules;
            })
            // {
              PrivateTmp = true;
            };
        };
        cosmos-hermes-inference = {
          description = "Inference-only local model interface for Hermes";
          wantedBy = [ "multi-user.target" ];
          after = [ "llama-swap.service" ];
          requires = [ "llama-swap.service" ];
          serviceConfig = {
            ExecStart = inferenceGateway;
            DynamicUser = true;
            Restart = "on-failure";
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            CapabilityBoundingSet = "";
            RestrictAddressFamilies = [ "AF_INET" ];
            IPAddressDeny = "any";
            IPAddressAllow = "localhost";
            MemoryMax = "256M";
            TasksMax = 32;
          };
        };
      }
      // lib.genAttrs [ "hermes-agent" "hermes-backend" ] (_: {
        requires = [
          "cosmos-hermes-egress.service"
          "cosmos-hermes-inference.service"
        ];
        after = [
          "cosmos-hermes-egress.service"
          "cosmos-hermes-inference.service"
        ];
        serviceConfig = hardening;
      });
    };
}
