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

      # The observability stack (observability.nix) for the agent: metrics, alerts and logs, read-only.
      observe = pkgs.rustPlatform.buildRustPackage {
        pname = "observe";
        version = "0.1.0";
        src = ./agent-tools/observe;
        cargoLock.lockFile = ./agent-tools/observe/Cargo.lock;
        meta.mainProgram = "observe";
      };

      # Long-term memory (memory-store.nix runs its Qdrant): items, session topics and past exchanges.
      memory = pkgs.rustPlatform.buildRustPackage {
        pname = "memory";
        version = "0.1.0";
        src = ./agent-tools/memory;
        cargoLock.lockFile = ./agent-tools/memory/Cargo.lock;
        # Under Nix, libsqlite3-sys links the system SQLite rather than its bundled copy.
        buildInputs = [ pkgs.sqlite ];
        meta.mainProgram = "memory";
      };
      hasMemory = cfg.tools ? memory;

      configFile = pkgs.writeText "agent-config.json" (
        builtins.toJSON {
          inherit (cfg)
            owner
            homeserver
            maxTurns
            testTools
            ;
          alerts = { inherit (cfg.alerts) port roomName; };
          memory = if hasMemory then { inherit (cfg.memory) quietMinutes roomName; } else null;
          schedules = lib.mapAttrs (_: s: { inherit (s) roomName prompt quiet; }) cfg.schedules;
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
          expose = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Offer the tool to the model; false keeps it for the agent's own code.";
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

        alerts = {
          port = lib.mkOption {
            type = lib.types.port;
            default = 8091;
            description = "Where the agent takes Alertmanager's webhook, on localhost.";
          };
          roomName = lib.mkOption {
            type = lib.types.str;
            default = "Alerts";
            description = "The room the agent makes for alerts, with the owner invited, on the first alert.";
          };
        };

        memory = {
          quietMinutes = lib.mkOption {
            type = lib.types.ints.positive;
            default = 30;
            description = "How long a room stays quiet before its session is consolidated into topics and items.";
          };
          roomName = lib.mkOption {
            type = lib.types.str;
            default = "Memory";
            description = "The room the agent makes, with the owner invited, to announce every memory change.";
          };
        };

        schedules = lib.mkOption {
          default = { };
          description = ''
            Jobs the agent runs on a timer, one file each in modules/timers/. Each becomes a systemd timer (see
            `systemctl list-timers`) that starts one run per hour at most, in the job's own room.
          '';
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                onCalendar = lib.mkOption {
                  type = lib.types.str;
                  description = "When, as systemd.time(7) calendar events, in lugh's time zone.";
                };
                roomName = lib.mkOption {
                  type = lib.types.str;
                  description = "The room the agent makes for the job, with the owner invited, on its first run.";
                };
                prompt = lib.mkOption {
                  type = lib.types.lines;
                  description = "What the job asks the agent to do.";
                };
                quiet = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Post nothing when there is nothing to report (the agent answers NOTHING).";
                };
              };
            }
          );
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
                  midConvoSystem = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = ''
                      The model's chat template accepts a system message later in a conversation, so a changed prompt
                      section (such as memory's core items) goes in there instead of rewriting the start, which keeps
                      llama.cpp's cache. Verified for workhorse (with its patched template) and helper/main (Gemma 4).
                    '';
                  };
                };
              }
            );
            default = {
              # 262K shared by its two slots (modules/hosts/nabu/llm.nix).
              workhorse = {
                contextWindow = 131072;
                reasoning = true;
                midConvoSystem = true;
              };
              main = {
                contextWindow = 32768;
                midConvoSystem = true;
              };
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

      config = lib.mkMerge [
        {
          # host-monitor, run locally: system, hardware, services, logs and config lookups, all read-only.
          agent.tools.monitor.command = lib.mkIf (config.monitor ? command) config.monitor.command;
          # Metrics, alerts and logs from every host, where the observability stack runs.
          agent.tools.observe.command = lib.mkIf config.services.prometheus.enable [ (lib.getExe observe) ];
          # Long-term memory, where its Qdrant runs. The model gets recall, get, list and the writes; indexing,
          # consolidation, announcements and undo are for the bridge.
          agent.tools.memory = lib.mkIf config.services.qdrant.enable {
            command = [
              (lib.getExe memory)
              "--data"
              "/var/lib/agent/memory.sqlite"
              "--qdrant"
              "http://127.0.0.1:${toString config.services.qdrant.settings.service.http_port}"
              "--models"
              (lib.removeSuffix "/v1" cfg.models.endpoint)
            ];
            tools =
              lib.genAttrs
                [
                  "remember"
                  "update"
                  "retract"
                  # marks what it returns as shown: a rerun after a crash would find nothing
                  "stale_threads"
                ]
                (_: {
                  replay = "unsafe";
                })
              //
                lib.genAttrs
                  [
                    "auto_recall"
                    "core_block"
                    "index_exchange"
                    "consolidate"
                    "unannounced"
                    "announced"
                    "notice"
                    "undo"
                  ]
                  (_: {
                    expose = false;
                  });
          };

          sops.secrets.agent-matrix-token.sopsFile = ../../secrets/${config.networking.hostName}.yaml;

          systemd.services.agent = {
            description = "Cosmos homelab agent";
            wantedBy = [ "multi-user.target" ];
            after = [
              "network-online.target"
              "netbird-wt0.service"
            ]
            ++ lib.optional config.services.matrix-tuwunel.enable "tuwunel.service"
            ++ lib.optional hasMemory "qdrant.service";
            wants = [ "network-online.target" ];
            restartTriggers = [ configFile ];
            serviceConfig = {
              ExecStart = "${lib.getExe nodejs} --disable-warning=ExperimentalWarning ${package}/lib/agent/dist/main.js ${configFile}";
              DynamicUser = true;
              StateDirectory = "agent";
              WorkingDirectory = "/var/lib/agent";
              # host-monitor's log tool reads the journal.
              SupplementaryGroups = [ "systemd-journal" ];
              LoadCredential = [
                "matrix-token:${config.sops.secrets.agent-matrix-token.path}"
              ]
              # memory reads it from $CREDENTIALS_DIRECTORY.
              ++ lib.optional hasMemory "qdrant-api-key:${config.sops.secrets.qdrant-api-key.path}";
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
        }

        {
          # The scheduler: each schedule's timer starts a oneshot that asks the agent (on localhost) to run the job. A run
          # missed while lugh was off happens at boot; a failed request (the agent restarting) is retried.
          systemd.services = lib.mapAttrs' (
            name: _:
            lib.nameValuePair "agent-schedule-${name}" {
              description = "Start the agent's ${name} job";
              after = [ "agent.service" ];
              serviceConfig = {
                Type = "oneshot";
                DynamicUser = true;
                ExecStart = "${lib.getExe pkgs.curl} --fail --silent --show-error --max-time 120 -X POST http://127.0.0.1:${toString cfg.alerts.port}/schedule/${name}";
                Restart = "on-failure";
                RestartSec = 60;
              };
              unitConfig.StartLimitIntervalSec = 0;
            }
          ) cfg.schedules;
          systemd.timers = lib.mapAttrs' (
            name: s:
            lib.nameValuePair "agent-schedule-${name}" {
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnCalendar = s.onCalendar;
                Persistent = true;
              };
            }
          ) cfg.schedules;
        }
      ];
    };
}
