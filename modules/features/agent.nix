# modules/features/agent.nix
{
  # The homelab's agent: a Pi Durable program (modules/features/agent, TypeScript) that talks with the owner in Matrix,
  # thinks with nabu's models through llama-swap, and uses the Rust tools listed in agent.tools as MCP servers.
  # Everything it can do is declared here and in that package; nothing it does changes its own setup. Each tool call
  # shows in Matrix, tools marked for approval wait for the owner's ✅, and it never deploys anything.
  #
  # Conversations, runs and the bridge's own state live in a SQLite database in /var/lib/agent, so a crash or restart
  # picks up where it stopped.
  flake.modules.nixos.agent =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.agent;
      nodejs = pkgs.nodejs_22;

      package = pkgs.buildNpmPackage {
        pname = "cosmos-agent";
        version = "0.1.0";
        src = lib.fileset.toSource {
          root = ./agent;
          fileset = lib.fileset.unions [
            ./agent/package.json
            ./agent/package-lock.json
            ./agent/tsconfig.json
            ./agent/src
          ];
        };
        inherit nodejs;
        npmDepsHash = "sha256-kjUMdoaMCW+z47GQSy17+e5h8etGXHsbYk/hk+ebwiA=";
        # No dependency needs an install script; skipping them keeps the build offline-clean.
        npmFlags = [ "--ignore-scripts" ];
        installPhase = ''
          runHook preInstall
          npm prune --omit=dev --ignore-scripts
          mkdir -p $out/lib/agent
          cp -r dist node_modules package.json $out/lib/agent/
          runHook postInstall
        '';
      };

      configFile = pkgs.writeText "agent-config.json" (
        builtins.toJSON {
          inherit (cfg)
            owner
            homeserver
            maxTurns
            testTools
            ;
          state = "/var/lib/agent/agent.sqlite";
          models = {
            inherit (cfg.models) endpoint default;
            catalog = cfg.models.catalog;
          };
          tools = lib.mapAttrs (_: server: { inherit (server) command replay tools; }) cfg.tools;
        }
      );

      toolPolicy = lib.types.submodule {
        options = {
          replay = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.enum [
                "safe"
                "unsafe"
              ]
            );
            default = null;
            description = "Overrides the server's replay policy for this tool.";
          };
          approval = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Wait for the owner's ✅ in Matrix before each call.";
          };
        };
      };
    in
    {
      options.agent = {
        owner = lib.mkOption {
          type = lib.types.str;
          default = "@twins:matrix.gatica.one";
          description = "The only Matrix account the agent listens to, joins rooms for, and takes approvals from.";
        };

        homeserver = lib.mkOption {
          type = lib.types.str;
          default = "https://matrix.gatica.one";
          description = "The Matrix homeserver of the agent's account (@agent).";
        };

        maxTurns = lib.mkOption {
          type = lib.types.ints.positive;
          default = 12;
          description = "Tool rounds one answer may take before the run stops.";
        };

        testTools = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Add a pretend restart_service tool behind the approval gate, for checking the gate.";
        };

        models = {
          endpoint = lib.mkOption {
            type = lib.types.str;
            default = "http://nabu.netbird.cloud:8080/v1";
            description = "nabu's llama-swap, reached through NetBird's CosmosModels policy.";
          };
          default = lib.mkOption {
            type = lib.types.str;
            default = "workhorse";
            description = "The model new conversations use.";
          };
          catalog = lib.mkOption {
            description = "The models the agent may use, by llama-swap name.";
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  contextWindow = lib.mkOption { type = lib.types.ints.positive; };
                  maxTokens = lib.mkOption {
                    type = lib.types.ints.positive;
                    default = 8192;
                  };
                  reasoning = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                  };
                };
              }
            );
            default = {
              # 262K shared by its two slots (modules/hosts/nabu/llm.nix).
              workhorse = {
                contextWindow = 131072;
                reasoning = true;
              };
              main.contextWindow = 32768;
            };
          };
        };

        tools = lib.mkOption {
          default = { };
          description = "MCP servers (stdio) whose tools the agent gets, named <server>__<tool>.";
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                command = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  description = "The server's argv.";
                };
                replay = lib.mkOption {
                  type = lib.types.enum [
                    "safe"
                    "unsafe"
                  ];
                  default = "safe";
                  description = ''
                    Whether a call cut off by a crash may run again. "safe" for read-only tools; "unsafe" ones report
                    "interrupted" to the model instead.
                  '';
                };
                tools = lib.mkOption {
                  type = lib.types.attrsOf toolPolicy;
                  default = { };
                  description = "Per-tool overrides, by the server's own tool name.";
                };
              };
            }
          );
        };
      };

      config = {
        # host-monitor, run locally: system, hardware, services, logs and config lookups, all read-only.
        agent.tools.monitor.command = lib.mkIf (config.monitor ? command) config.monitor.command;

        sops.secrets.agent-matrix-token.sopsFile = ../../secrets/${config.networking.hostName}.yaml;

        systemd.services.agent = {
          description = "Cosmos homelab agent";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network-online.target"
            "netbird-wt0.service"
          ]
          ++ lib.optional config.services.matrix-tuwunel.enable "tuwunel.service";
          wants = [ "network-online.target" ];
          restartTriggers = [ configFile ];
          serviceConfig = {
            ExecStart = "${lib.getExe nodejs} --disable-warning=ExperimentalWarning ${package}/lib/agent/dist/main.js ${configFile}";
            DynamicUser = true;
            StateDirectory = "agent";
            WorkingDirectory = "/var/lib/agent";
            # host-monitor's log tool reads the journal.
            SupplementaryGroups = [ "systemd-journal" ];
            LoadCredential = [ "matrix-token:${config.sops.secrets.agent-matrix-token.path}" ];
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
            RestrictNamespaces = true;
            LockPersonality = true;
            RestrictSUIDSGID = true;
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];
          };
        };

        monitor.units = [ "agent" ];
      };
    };
}
