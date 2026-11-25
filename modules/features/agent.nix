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

      # The chat web app (agent/web, Svelte): type-checked (templates included) before it is built, so a type error or a
      # warning fails the build. It imports the API's types from the agent (agent/src/api.ts).
      chatWeb = pkgs.buildNpmPackage {
        pname = "cosmos-chat-web";
        version = "0.1.0";
        src = lib.fileset.toSource {
          root = ./agent;
          fileset = lib.fileset.unions [
            ./agent/src/api.ts
            (lib.fileset.difference ./agent/web (
              lib.fileset.unions [
                (lib.fileset.maybeMissing ./agent/web/node_modules)
                (lib.fileset.maybeMissing ./agent/web/dist)
              ]
            ))
          ];
        };
        sourceRoot = "source/web";
        inherit nodejs;
        npmDepsHash = "sha256-9TXrzjiV3DhMSmEfbn2GJIEISaSFBaz6YxkbAbGJHaE=";
        npmFlags = [ "--ignore-scripts" ];
        buildPhase = ''
          runHook preBuild
          npm run check
          npm run build
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          cp -r dist $out
          runHook postInstall
        '';
      };

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
          cp -r ${chatWeb} $out/lib/agent/web
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

      # The web through Tavily: search and page reading.
      web = pkgs.rustPlatform.buildRustPackage {
        pname = "web";
        version = "0.1.0";
        src = ./agent-tools/web;
        cargoLock.lockFile = ./agent-tools/web/Cargo.lock;
        meta.mainProgram = "web";
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
          topology = if cfg.topologyFile == null then null else "${cfg.topologyFile}";
          netbirdDeclared = if cfg.netbirdDeclared == null then null else "${cfg.netbirdDeclared}";
          chat =
            if cfg.chat.enable then
              {
                inherit (cfg.chat)
                  roomName
                  port
                  mainModel
                  workModel
                  titleModel
                  ;
              }
            else
              null;
          state = "/var/lib/agent/agent.sqlite";
          models = {
            inherit (cfg.models) endpoint default;
            catalog = cfg.models.catalog;
          };
          tools = lib.mapAttrs (_: server: {
            inherit (server)
              command
              replay
              about
              tools
              ;
          }) cfg.tools;
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

      # The notes tool for one vault: reading is safe to repeat after a crash; a write might have happened, so it
      # isn't, and changing or moving an existing note waits for the owner.
      vaultTools =
        { vault, about }:
        {
          command = [
            (lib.getExe config.notes.package)
            "--vault"
            vault
            "serve"
          ];
          inherit about;
          tools = {
            create.replay = "unsafe";
            edit = {
              replay = "unsafe";
              approval = true;
            };
            move = {
              replay = "unsafe";
              approval = true;
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

        chat = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Chats with the owner's models: a web app at chat.<domain> (mesh-only, behind Pocket ID or the chat-password secret) and
              a Chat room in Matrix, sharing the same conversations. A chat starts on mainModel, which hands it to
              workModel (with the homelab tools) when the talk turns to work.
            '';
          };
          sso = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Sign in with Pocket ID (web.sites.chat.sso) instead of the app's own password: the agent then trusts that
              nginx lets only signed-in requests through, and chat-password isn't used.
            '';
          };
          roomName = lib.mkOption {
            type = lib.types.str;
            default = "Chat";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 8092;
            description = "The web app's port on 127.0.0.1.";
          };
          mainModel = lib.mkOption {
            type = lib.types.str;
            default = "main";
          };
          workModel = lib.mkOption {
            type = lib.types.str;
            default = "workhorse";
          };
          titleModel = lib.mkOption {
            type = lib.types.str;
            default = "helper";
            description = "The llama-swap model that names chats.";
          };
        };

        web = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Give investigations, campaign chats and work chats web search and page reading (Tavily; its key is tavily-api-key in secrets/common.yaml).";
        };

        netbirdApi = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Give the agent the read-only NetBird token, for the netbird_access tool (policies, groups, peers).";
        };

        netbirdDeclared = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "modules/netbird-policies.nix as JSON (set there), for netbird_access's drift view.";
        };

        topologyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "The homelab map as markdown (set by modules/topology.nix), for the homelab_map tool.";
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
                about = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = "[The campaigns vault]";
                  description = "Put before each of its tools' descriptions, to tell servers of the same program apart.";
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
          # The owner's Obsidian vaults, where they sync (notes.nix): the notes vault, and the campaigns vault (D&D)
          # when it's one of the extras. New notes go straight into a vault's inbox; edits and moves wait for the
          # owner's ✅ (shown as a diff). Nothing is deleted.
          agent.tools.notes = lib.mkIf (config ? notes) (vaultTools {
            vault = config.notes.vault;
            about = "[Notes vault: the owner's personal notes; its rules: Reference/How this vault works]";
          });
          agent.tools.campaign =
            lib.mkIf (config ? notes && config.notes.extraVaultPaths ? campaigns)
              (vaultTools {
                vault = config.notes.extraVaultPaths.campaigns;
                about = "[Campaigns vault: the owner's D&D campaigns and worlds; its rules: AGENTS.md]";
              });
          # The same vault, read-only, for the background investigator of campaign chats.
          agent.tools.lore = lib.mkIf (config ? notes && config.notes.extraVaultPaths ? campaigns) {
            command = [
              (lib.getExe config.notes.package)
              "--vault"
              config.notes.extraVaultPaths.campaigns
              "serve"
              "--read-only"
            ];
            about = "[Campaigns vault, read-only: the owner's D&D campaigns and worlds; its rules: AGENTS.md]";
            tools = lib.genAttrs [ "create" "edit" "move" ] (_: {
              expose = false;
            });
          };
          # Web search and page reading; the bridge gives them to investigations, campaign chats and work chats only.
          agent.tools.web = lib.mkIf cfg.web {
            command = [ (lib.getExe web) ];
            about = "[Web]";
          };
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
                    "status"
                    "unannounced"
                    "announced"
                    "notice"
                    "undo"
                  ]
                  (_: {
                    expose = false;
                  });
          };

          # For the homelab map (modules/topology.nix): what the agent is and what it can reach, from its own options.
          topology.self.services.agent = {
            name = "Cosmos agent";
            icon = "services.open-webui";
            info = "Matrix bot @agent${lib.optionalString cfg.chat.enable ", chat.gatica.one"}";
            details = {
              models.text = "thinks with nabu's llama-swap (${cfg.models.endpoint}); default ${cfg.models.default}, may use ${lib.concatStringsSep ", " (lib.attrNames cfg.models.catalog)}";
              tools.text = "MCP servers: ${lib.concatStringsSep ", " (lib.attrNames cfg.tools)}";
              schedules.text =
                if cfg.schedules == { } then
                  "none"
                else
                  lib.concatStringsSep "; " (lib.mapAttrsToList (n: sc: "${n} (${sc.onCalendar})") cfg.schedules);
              hooks.text = "Alertmanager webhook and schedule triggers on 127.0.0.1:8091${lib.optionalString cfg.chat.enable "; chat web app on 127.0.0.1:${toString cfg.chat.port}"}";
            };
          };

          sops.secrets.agent-matrix-token.sopsFile = ../../secrets/${config.networking.hostName}.yaml;
          sops.secrets.chat-password = lib.mkIf (cfg.chat.enable && !cfg.chat.sso) {
            sopsFile = ../../secrets/${config.networking.hostName}.yaml;
          };
          # The read-only NetBird token (CosmosAuditor, modules/features/netbird-api.nix) for the netbird_access tool.
          sops.secrets.tavily-api-key = lib.mkIf cfg.web {
            sopsFile = ../../secrets/common.yaml;
          };
          sops.secrets.netbird-api-token = lib.mkIf cfg.netbirdApi {
            sopsFile = ../../secrets/common.yaml;
          };
          # tenjin pushes its wallpaper palette with this (modules/desktop/chat-theme.nix); shared, so common.yaml.
          sops.secrets.chat-theme-token = lib.mkIf cfg.chat.enable {
            sopsFile = ../../secrets/common.yaml;
          };

          # The chat web app; streaming answers need nginx to pass events through as they come.
          web.sites.chat = lib.mkIf cfg.chat.enable {
            inherit (cfg.chat) port;
            healthPath = "/healthz";
            inherit (cfg.chat) sso;
            # tenjin's palette push brings its own token (chat-theme-token).
            ssoBypass = [ "/api/theme" ];
            homepage = {
              name = "Chat";
              group = "Apps";
              icon = "mdi-chat-processing";
              description = "The homelab agent and the models on nabu";
            };
            extraConfig = ''
              proxy_buffering off;
              proxy_cache off;
              proxy_read_timeout 1h;
            '';
          };

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
              # host-monitor's log tool reads the journal; the notes tool, the vault.
              SupplementaryGroups = [ "systemd-journal" ] ++ lib.optional (config ? notes) "notes";
              # The notes tools write into the vaults; folders they make stay writable by the group (and keep the
              # vault's setgid, so files in them stay the notes group's), for the sync service.
              ReadWritePaths = lib.optionals (config ? notes) (
                [ config.notes.vault ] ++ lib.attrValues config.notes.extraVaultPaths
              );
              UMask = "0007";
              LoadCredential = [
                "matrix-token:${config.sops.secrets.agent-matrix-token.path}"
              ]
              # memory reads it from $CREDENTIALS_DIRECTORY.
              ++ lib.optional hasMemory "qdrant-api-key:${config.sops.secrets.qdrant-api-key.path}"
              # web reads it from $CREDENTIALS_DIRECTORY.
              ++ lib.optional cfg.web "tavily-api-key:${config.sops.secrets.tavily-api-key.path}"
              ++ lib.optional cfg.netbirdApi "netbird-api-token:${config.sops.secrets.netbird-api-token.path}"
              ++ lib.optional cfg.chat.enable "chat-theme-token:${config.sops.secrets.chat-theme-token.path}"
              ++ lib.optional (
                cfg.chat.enable && !cfg.chat.sso
              ) "chat-password:${config.sops.secrets.chat-password.path}";
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
