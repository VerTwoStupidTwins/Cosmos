# modules/features/memory-store.nix
{
  # Long-term memory and search by meaning, on Qdrant.
  #
  # The memory service: the Rust memory server (agent-tools/memory) serving MCP over HTTP on loopback for Hermes and
  # its memory plugin (hermes.nix), and consolidating conversations once they go quiet. Its SQLite file is the truth;
  # Qdrant only indexes it, so the collection can be wiped and rebuilt from that at any time. On its first start it took
  # over the database of the Matrix agent that came before it.
  #
  # Search by meaning in the notes vaults: each vault has a collection of its own, embedded and reranked by nabu's
  # models, and a <collection>-index service that keeps it in step. The notes tools search it (memory.vaultSearchArgs).
  #
  # Qdrant listens on localhost; its dashboard is at memory.gatica.one (mesh only), opened with the read-only key.
  flake.modules.nixos.memory-store =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      port = 6333;
      hostSecrets = ../../secrets/${config.networking.hostName}.yaml;

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

      # Each vault by its collection's name, where the notes vaults are (notes.nix).
      indexedVaults = lib.optionalAttrs (config ? notes) (
        {
          notes = config.notes.vault;
        }
        // lib.mapAttrs' (name: path: lib.nameValuePair "notes-${name}" path) config.notes.extraVaultPaths
      );
      vaultSearchArgs = collection: [
        "--qdrant"
        "http://127.0.0.1:${toString port}"
        "--collection"
        collection
        "--models"
        "http://nabu.netbird.cloud:8080/v1"
        # Obsidian Copilot's saved chats and skill docs: the plugin's files, not the owner's notes.
        "--exclude"
        "copilot"
      ];

      # Once, before the first start: a consistent copy of the old Matrix agent's memory database, if there is one.
      takeOver = pkgs.writeShellScript "memory-take-over" ''
        if [ ! -e ${stateDir}/memory.sqlite ] && [ -e ${agentDatabase} ]; then
          ${lib.getExe pkgs.sqlite} ${agentDatabase} ".backup '${stateDir}/memory.sqlite'"
          chown memory:memory ${stateDir}/memory.sqlite
          echo "memory: took over the agent's database (${agentDatabase})"
        fi
      '';
    in
    {
      options.memory = {
        url = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = "http://127.0.0.1:${toString servicePort}/mcp";
          description = "The memory service's MCP endpoint, for Hermes.";
        };
        vaultSearchArgs = lib.mkOption {
          type = lib.types.functionTo (lib.types.listOf lib.types.str);
          readOnly = true;
          default = vaultSearchArgs;
          description = "The notes tool's arguments for searching a vault's collection by meaning.";
        };
      };

      config = lib.mkMerge [
        {
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
        }

        {
          # Re-embeds a vault's notes as they change (a few seconds after a save), and at least hourly; searches catch
          # up on anything newer themselves.
          systemd.services = lib.mapAttrs' (
            collection: vault:
            lib.nameValuePair "${collection}-index" {
              description = "Keep the search index of the vault at ${vault} in step with it";
              wantedBy = [ "multi-user.target" ];
              wants = [ "network-online.target" ];
              after = [
                "network-online.target"
                "netbird-wt0.service"
                "qdrant.service"
              ];
              serviceConfig = {
                ExecStart = lib.escapeShellArgs (
                  [
                    (lib.getExe config.notes.package)
                    "--vault"
                    vault
                    "index"
                  ]
                  ++ vaultSearchArgs collection
                );
                DynamicUser = true;
                # Reads the vault; writes only to Qdrant.
                SupplementaryGroups = [ "notes" ];
                LoadCredential = [ "qdrant-api-key:${config.sops.secrets.qdrant-api-key.path}" ];
                ProtectHome = true;
                PrivateTmp = true;
                NoNewPrivileges = true;
                Restart = "always";
                RestartSec = 30;
              };
            }
          ) indexedVaults;

          monitor.units = map (collection: "${collection}-index") (lib.attrNames indexedVaults);
        }
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
            details.role.text = "Memory and vault search index (dense + BM25 vectors); memory's truth is SQLite in /var/lib/memory.";
          };

          web.sites.memory = {
            inherit port;
            healthPath = "/healthz";
            homepage = {
              name = "Memory";
              group = "Infrastructure";
              icon = "qdrant.png";
              description = "Qdrant: long-term memory and vault search";
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
