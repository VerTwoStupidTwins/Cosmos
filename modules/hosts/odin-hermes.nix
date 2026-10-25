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
            meta skuid "hermes" ip daddr 127.0.0.1 tcp dport { 18090, 18092 } accept
            # The dashboard PTY's authenticated WS callback targets this host.
            meta skuid "hermes" meta nfproto ipv4 fib daddr type local tcp dport 9119 accept
            meta skuid "hermes" counter reject
          }
        }
      '';
      hardening = {
        # Hide personal homes and the user manager. Native Kanban dispatch
        # uses its profile owner; it does not need the systemd user bus.
        ProtectHome = lib.mkForce "tmpfs";
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
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
      imports = [ nixos."hermes-local" ];
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
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.nftables}/bin/nft --file ${egressRules}";
            # Deliberately no ExecStop: stopping the controller must not release
            # surviving same-UID workers onto the network.
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            CapabilityBoundingSet = "CAP_NET_ADMIN";
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_NETLINK"
            ];
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
        hermes-agent = {
          requires = [
            "cosmos-hermes-egress.service"
            "cosmos-hermes-inference.service"
          ];
          after = [
            "cosmos-hermes-egress.service"
            "cosmos-hermes-inference.service"
          ];
          serviceConfig = hardening;
        };
        hermes-backend = {
          requires = [
            "cosmos-hermes-egress.service"
            "cosmos-hermes-inference.service"
          ];
          after = [
            "cosmos-hermes-egress.service"
            "cosmos-hermes-inference.service"
          ];
          serviceConfig = hardening;
        };
      };
    };
}
