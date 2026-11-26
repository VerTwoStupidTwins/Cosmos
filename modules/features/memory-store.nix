# modules/features/memory-store.nix
{
  # Qdrant, the search index of the agent's long-term memory (agent.nix runs the memory server that owns it). It holds
  # only what the memory server's SQLite file holds, so it can be wiped and rebuilt from that at any time. It listens
  # on localhost; its dashboard is at memory.gatica.one (mesh only), opened with the read-only key.
  #
  # The memory service: the Rust memory server (agent-tools/memory) running on its own, serving MCP over HTTP on
  # loopback for Hermes and its memory plugin (hermes.nix), and consolidating conversations once they go quiet. It only
  # runs once the Matrix agent is gone: until then that agent runs its own copy of the server over stdio on the same
  # Qdrant collection, and two writers would split memory. On its first start it takes over the agent's database.
  flake.modules.nixos.memory-store =
    {
      config,
      options,
      lib,
      pkgs,
      ...
    }:
    let
      port = 6333;
      hostSecrets = ../../secrets/${config.networking.hostName}.yaml;

      serve = !(options ? agent);
      servicePort = 8095;
      stateDir = "/var/lib/memory";
      agentDatabase = "/var/lib/agent/memory.sqlite";

      memory = pkgs.rustPlatform.buildRustPackage {
        pname = "memory";
        version = "0.1.0";
        src = ./agent-tools/memory;
        cargoLock.lockFile = ./agent-tools/memory/Cargo.lock;
        # Under Nix, libsqlite3-sys links the system SQLite rather than its bundled copy.
        buildInputs = [ pkgs.sqlite ];
        meta.mainProgram = "memory";
      };

      # Once, before the first start: a consistent copy of the Matrix agent's memory database, if there is one.
      takeOver = pkgs.writeShellScript "memory-take-over" ''
        if [ ! -e ${stateDir}/memory.sqlite ] && [ -e ${agentDatabase} ]; then
          ${lib.getExe pkgs.sqlite} ${agentDatabase} ".backup '${stateDir}/memory.sqlite'"
          chown memory:memory ${stateDir}/memory.sqlite
          echo "memory: took over the agent's database (${agentDatabase})"
        fi
      '';
    in
    {
      options.memory.url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        readOnly = true;
        default = if serve then "http://127.0.0.1:${toString servicePort}/mcp" else null;
        description = "The memory service's MCP endpoint, for Hermes; null while the Matrix agent owns memory.";
      };

      config = lib.mkMerge [
        (lib.mkIf serve {
          users.users.memory = {
            isSystemUser = true;
            group = "memory";
          };
          users.groups.memory = { };

          systemd.services.memory = {
            description = "Long-term memory (MCP over HTTP on loopback)";
            wantedBy = [ "multi-user.target" ];
            after = [
              "qdrant.service"
              "network-online.target"
            ];
            wants = [
              "qdrant.service"
              "network-online.target"
            ];
            serviceConfig = {
              User = "memory";
              Group = "memory";
              StateDirectory = "memory";
              StateDirectoryMode = "0700";
              ExecStartPre = "+${takeOver}";
              ExecStart = lib.escapeShellArgs [
                (lib.getExe memory)
                "--data"
                "${stateDir}/memory.sqlite"
                "--qdrant"
                "http://127.0.0.1:${toString port}"
                # nabu's llama-swap: embedding, reranker, and helper for consolidation.
                "--models"
                "http://nabu.netbird.cloud:8080"
                "--listen"
                "127.0.0.1:${toString servicePort}"
                "--hermes"
              ];
              # memory reads it from $CREDENTIALS_DIRECTORY.
              LoadCredential = [ "qdrant-api-key:${config.sops.secrets.qdrant-api-key.path}" ];
              Restart = "always";
              RestartSec = 5;
              NoNewPrivileges = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              PrivateDevices = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              RestrictAddressFamilies = [
                "AF_INET"
                "AF_INET6"
                "AF_UNIX"
              ];
              RestrictNamespaces = true;
              LockPersonality = true;
              MemoryDenyWriteExecute = true;
              SystemCallArchitectures = "native";
            };
          };

          monitor = {
            units = [ "memory" ];
            ports.memory = servicePort;
          };
        })
        {
          # The read/write key is the memory server's; the read-only key opens the dashboard and lets Prometheus scrape.
          sops.secrets.qdrant-api-key.sopsFile = hostSecrets;
          sops.secrets.qdrant-read-key = {
            sopsFile = hostSecrets;
            owner = lib.mkIf config.services.prometheus.enable "prometheus";
          };
          sops.templates."qdrant.env".content = ''
            QDRANT__SERVICE__API_KEY=${config.sops.placeholder.qdrant-api-key}
            QDRANT__SERVICE__READ_ONLY_API_KEY=${config.sops.placeholder.qdrant-read-key}
          '';

          services.qdrant = {
            enable = true;
            # nixpkgs' 1.18.2 fails to build: its zstd-sys looks for the system libzstd through pkg-config, which the
            # package doesn't provide. Its own test suite is skipped; the memory server's tests run against it instead.
            package = pkgs.qdrant.overrideAttrs (old: {
              buildInputs = old.buildInputs ++ [ pkgs.zstd ];
              doCheck = false;
            });
            settings = {
              service = {
                host = "127.0.0.1";
                http_port = port;
                grpc_port = null; # REST only
                enable_cors = false;
              };
              telemetry_disabled = true;
              # Its metrics read /proc/sys/vm/max_map_count, which the service's sandbox hides, and warn every 30 s.
              log_level = "INFO,qdrant::common::metrics=error";
            };
          };
          # The keys come from the environment, never the config file in the Nix store.
          systemd.services.qdrant.serviceConfig.EnvironmentFile = config.sops.templates."qdrant.env".path;

          # For the homelab map (modules/topology.nix).
          topology.self.services.qdrant = {
            name = "Qdrant";
            info = "127.0.0.1:6333, dashboard memory.gatica.one";
            details.role.text = "The agent's memory index (dense + BM25 vectors); the truth is SQLite in /var/lib/agent.";
          };

          web.sites.memory = {
            inherit port;
            healthPath = "/healthz";
            homepage = {
              name = "Agent memory";
              group = "Infrastructure";
              icon = "qdrant.png";
              description = "Qdrant, the agent's long-term memory";
              path = "/dashboard";
            };
          };

          # promtool can't check a credentials file that only exists at runtime (sops), so only the syntax is checked.
          services.prometheus.checkConfig = lib.mkIf config.services.prometheus.enable "syntax-only";
          services.prometheus.scrapeConfigs = lib.mkIf config.services.prometheus.enable [
            {
              job_name = "qdrant";
              static_configs = [
                {
                  targets = [ "127.0.0.1:${toString port}" ];
                  labels.host = config.networking.hostName;
                }
              ];
              authorization.credentials_file = config.sops.secrets.qdrant-read-key.path;
            }
          ];

          monitor.units = [ "qdrant" ];
        }
      ];
    };
}
