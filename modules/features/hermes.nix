# modules/features/hermes.nix
{ inputs, ... }:
let
  # The dashboard's address. Phones, the desktop app and browsers reach it only over NetBird (web.nix).
  site = "hermes";
  domain = "gatica.one";
  publicUrl = "https://${site}.${domain}";
in
{
  # Hermes Agent (github:NousResearch/hermes-agent) on lugh: the gateway that runs the agent, its scheduled jobs and
  # tools, and the backend that the dashboard, Hermes Desktop on tenjin and the Hermes phone app talk to. It thinks with
  # nabu's models through llama-swap. Our own pieces plug in the way they always have: Rust binaries do the work
  # (agent-tools/, MCP servers), and small Python plugins hook them into Hermes.
  flake.modules.nixos.hermes =
    {
      config,
      options,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.hermes-agent;
      port = 9119;

      # nabu's llama-swap, reached through NetBird's CosmosModels policy. The roles are modules/hosts/nabu/llm.nix's.
      models = "http://nabu.netbird.cloud:8080/v1";
      # llama-swap takes no key, but Hermes' OpenAI-style clients refuse to run without one.
      modelKey = "local";
      onNabu = model: timeout: {
        # With base_url set, Hermes calls that endpoint directly and ignores the provider.
        base_url = models;
        api_key = modelKey;
        inherit model timeout;
      };

      # Pocket ID's "Hermes" client (identity.nix; made through its API, cosmos group only, callback
      # https://hermes.gatica.one/auth/callback). The username and password still sign in when Pocket ID can't.
      oidcClientId = "c32ad4e2-65da-445d-8efc-44f8bec9384f";

      # Our long-term memory (memory-store.nix serves it). Hermes names a Nix-managed plugin
      # nix-managed-<derivation name>, and that's the provider's name too.
      memoryUrl = config.memory.url;
      memoryPlugin = pkgs.runCommand "cosmos-memory" { } ''
        cp -r ${./hermes/memory-plugin} $out
      '';

      # The owner's Obsidian vaults, where they sync (notes.nix), and their search indexes (memory-store.nix).
      campaignsVault = config.notes.extraVaultPaths.campaigns;
      # The notes tool serving one vault: its search by meaning, then the serve flags.
      vaultServer = vault: collection: serveArgs: {
        command = lib.getExe config.notes.package;
        args = [
          "--vault"
          vault
          "serve"
        ]
        ++ serveArgs
        ++ config.memory.vaultSearchArgs collection
        ++ [
          "--qdrant-key-file"
          config.sops.secrets.qdrant-api-key-hermes.path
        ];
      };

      # The art tool (agent-tools/art): pictures from nabu's image model, kept in Hermes' state.
      art = pkgs.rustPlatform.buildRustPackage {
        pname = "art";
        version = "0.1.0";
        src = ./agent-tools/art;
        cargoLock.lockFile = ./agent-tools/art/Cargo.lock;
        meta.mainProgram = "art";
      };
      # Qwen-Image 2.1's 4-step LoRA, by its path on nabu (modules/hosts/nabu/llm.nix): sd-server needs it with each
      # request.
      imageLora = "/models/image/qwen-image-2.1/loras/lightx2v-4step.safetensors";

      # Plugins from Hermes' plugin catalog, at the commits it lists.
      # Nous Research's official provider for Claude through the owner's subscription, via the Claude Code CLI.
      claudePlugin = pkgs.runCommand "claude-subscription-directsdk" { } ''
        cp -r ${
          pkgs.fetchFromGitHub {
            owner = "NousResearch";
            repo = "hermes-official-plugins";
            rev = "968160cec673d7c41b225e51604cc47048ceca8f";
            hash = "sha256-ispIxsQgIYNYUl6i+u6+r254E2dW0JF056Oq7bxUtqg=";
          }
        }/claude-subscription-directsdk $out
      '';
      # Compaction without a model call: the summary keeps commands, errors and files, each linked to its message.
      vccPlugin = pkgs.fetchFromGitHub {
        name = "hermes-vcc-engine";
        owner = "danbiocchi";
        repo = "hermes-vcc-engine";
        rev = "4d8add79395c56b785fd730bbc78c5fcd7194b59";
        hash = "sha256-FxsUoK/LulPO6LLHoKoFdC3lYmytNyhMMD+0pSyJDSw=";
      };
      # Plan mode: Hermes explores read-only and writes a plan; its writes, terminal and MCP tools wait until the owner
      # approves it.
      planModePlugin = pkgs.fetchFromGitHub {
        name = "plan-mode";
        owner = "100yenadmin";
        repo = "hermes-plan-mode";
        rev = "4619a8dca04451bf628f849897bddf0b90669eb2";
        hash = "sha256-pcJ7tKqfJZA0xuTqysTze8VUDda9i3052b+5jg0mCnU=";
      };
      # Obsidian's own skills, for writing the vault's Markdown, Bases and Canvas files properly. Only those three:
      # the CLI skill needs the desktop app, which lugh doesn't run; Headless signs into the Obsidian account, and the
      # vault's sync isn't Hermes' business; Defuddle and Knap install npm packages when first used.
      obsidianPlugin =
        let
          src = pkgs.fetchFromGitHub {
            owner = "obsidianmd";
            repo = "obsidian-skills";
            rev = "a53f5910cd68e7bad88ea52f2f4eb95b9aa40800";
            hash = "sha256-CBBR/Q9DlnSIypdWtaF+usOjHb8Pt0NP+E+LUgAoaIg=";
          };
        in
        pkgs.runCommand "obsidian" { } ''
          mkdir -p $out/skills
          cp ${src}/plugins/obsidian/{plugin.json,LICENSE} $out/
          cp -r ${src}/plugins/obsidian/skills/{obsidian-markdown,obsidian-bases,json-canvas} $out/skills/
        '';
      # Ours: research subagents on Claude, deep dives on its strongest model, every other subagent local.
      researchRoutingPlugin = pkgs.runCommand "research-routing" { } ''
        cp -r ${./hermes/research-routing} $out
      '';

      hermesHome = "${cfg.stateDir}/.hermes";
      skillsDir = "${hermesHome}/skills";
      claudePluginDir = "${hermesHome}/plugins/${claudePlugin.name}";

      # Hermes copies its bundled skills out of the Nix store with the store's read-only modes, so it can't edit or
      # patch them. The modes aren't part of the hash Hermes uses to spot user edits, so this doesn't stop updates.
      unlockSkills = ''
        if [ -d ${skillsDir} ]; then
          find ${skillsDir} -user hermes \( -type d -o -type f \) ! -perm -u+w,g+w -exec chmod u+w,g+w {} + || true
        fi
      '';

    in
    {
      imports = [ inputs.hermes-agent.nixosModules.default ];

      sops.secrets = {
        # Hermes Desktop on tenjin presents it, so it's shared (common.yaml).
        hermes-desktop-token = {
          sopsFile = ../../secrets/common.yaml;
          owner = "hermes";
          mode = "0400";
          restartUnits = [ "hermes-backend.service" ];
        };
        tavily-api-key.sopsFile = ../../secrets/common.yaml;
        # Qdrant's key again, for the wiki tool's search by meaning: Hermes starts its MCP servers itself, so they get
        # no systemd credentials.
        qdrant-api-key-hermes = {
          sopsFile = ../../secrets/${config.networking.hostName}.yaml;
          key = "qdrant-api-key";
          owner = "hermes";
          mode = "0400";
        };
        # The dashboard's own sign-in, for when Pocket ID is down or an app can't use it.
        hermes-dashboard-password.sopsFile = ../../secrets/${config.networking.hostName}.yaml;
        hermes-dashboard-secret.sopsFile = ../../secrets/${config.networking.hostName}.yaml;
      }
      // lib.optionalAttrs (oidcClientId != null) {
        hermes-oidc-secret.sopsFile = ../../secrets/${config.networking.hostName}.yaml;
      };

      # Activation copies this into Hermes' .env, which Hermes reads only when it starts.
      sops.templates."hermes.env" = {
        content = ''
          TAVILY_API_KEY=${config.sops.placeholder.tavily-api-key}
          HERMES_DASHBOARD_BASIC_AUTH_USERNAME=twins
          HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${config.sops.placeholder.hermes-dashboard-password}
          HERMES_DASHBOARD_BASIC_AUTH_SECRET=${config.sops.placeholder.hermes-dashboard-secret}
        ''
        + lib.optionalString (oidcClientId != null) ''
          HERMES_DASHBOARD_OIDC_ISSUER=https://id.${domain}
          HERMES_DASHBOARD_OIDC_CLIENT_ID=${oidcClientId}
          HERMES_DASHBOARD_OIDC_CLIENT_SECRET=${config.sops.placeholder.hermes-oidc-secret}
        '';
        restartUnits = [
          "hermes-agent.service"
          "hermes-backend.service"
        ];
      };

      # The dashboard, through nginx with the wildcard certificate. Nothing signs in in front of it: the desktop and
      # phone apps bring their own credentials, and the dashboard asks everyone else to sign in.
      web.sites.${site} = {
        inherit port;
        healthPath = "/api/health";
        websockets = true;
        # Desktop attachments arrive in one frame of up to 384 MiB.
        extraConfig = ''
          client_max_body_size 400m;
          proxy_read_timeout 1h;
          proxy_send_timeout 1h;
        '';
        homepage = {
          name = "Hermes";
          group = "Apps";
          icon = "mdi-robot-happy-outline";
          description = "The agent: chats, memory, skills, schedules";
        };
      };

      topology.self.services.hermes = {
        name = "Hermes";
        info = "${site}.${domain}";
        details.role.text = "The homelab's agent: desktop, phone and web chats, thinking with nabu's models.";
      };

      monitor.units = [
        "hermes-agent"
        "hermes-backend"
      ];

      # Lets twins read Hermes' config, logs and skills, and add skills to its skills folder.
      users.users.twins.extraGroups = [ "hermes" ];

      # The vault tools write into the Notes and Campaigns vaults, which are the notes group's (notes.nix). Hermes'
      # services see the rest of the system read-only, so the vaults are opened for writing too.
      users.users.hermes.extraGroups = [ "notes" ];

      # With twins in the group, Hermes counts a group-writable home as unsafe and refuses to reach its gateway, which
      # fails every cron job. The module makes the home 2770 at boot (tmpfiles) and on every switch (activation), so
      # both are overridden: tmpfiles keeps the first line for a path, and this script runs after the module's.
      systemd.tmpfiles.rules = lib.mkBefore [ "d ${hermesHome} 2750 hermes hermes - -" ];
      #
      # Hermes stages a model-provider plugin by copying it and renaming the copy into place, which fails for a
      # read-only directory from the Nix store (extraPlugins). The Claude provider gets a writable copy instead, made
      # fresh on every boot and switch; its timestamps are kept, so Hermes sees it as changed only when it is.
      # Obsidian's plugin is an Agent Plugin (plugin.json, no plugin.yaml), which extraPlugins refuses, so it's linked
      # here too.
      system.activationScripts.hermes-home-private = lib.stringAfter [ "hermes-agent-setup" ] ''
        chmod 2750 ${hermesHome}
        ${unlockSkills}
        rm -rf ${claudePluginDir}
        cp -r --no-preserve=mode --preserve=timestamps ${claudePlugin} ${claudePluginDir}
        chown -R hermes:hermes ${claudePluginDir}
        ln -sfn ${obsidianPlugin} ${hermesHome}/plugins/obsidian
      '';

      # Hermes copies new bundled skills as it starts, so each start also unlocks the ones the previous start copied.
      # The repo carries no skills: they're Hermes' own, kept in its state and changed only by Hermes or the owner.
      # Conversations start with memory's core block, so Hermes waits for the memory service.
      systemd.services.hermes-agent = {
        preStart = lib.mkAfter unlockSkills;
        after = [ "memory.service" ];
        wants = [ "memory.service" ];
        serviceConfig.ReadWritePaths = [
          config.notes.vault
          campaignsVault
        ];
      };
      systemd.services.hermes-backend = {
        after = [ "memory.service" ];
        wants = [ "memory.service" ];
        serviceConfig.ReadWritePaths = [
          config.notes.vault
          campaignsVault
        ];
      };

      services.hermes-agent = {
        enable = true;
        addToSystemPackages = true;

        # The flake builds Hermes without a version, so it calls itself 0.0.0, and plugins that ask for a minimum
        # Hermes (VCC, the Claude provider, plan mode) are skipped. This is the release the pinned commit builds on:
        # `git describe --tags --match 'v0.*' <rev>` in Hermes' repo. Update it with the flake input.
        package = options.services.hermes-agent.package.default.override { version = "0.23.4"; };

        # The dashboard (with everything Hermes Desktop and the phone app use), on loopback behind nginx.
        # dashboard.public_url below makes Hermes trust that name and ask for sign-in.
        backend = {
          mode = "dashboard";
          host = "127.0.0.1";
          inherit port;
          sessionTokenFile = config.sops.secrets.hermes-desktop-token.path;
        };

        environment = {
          # Voice messages go to nabu's Whisper through Hermes' OpenAI-style transcription, which also needs a key.
          STT_OPENAI_BASE_URL = models;
          VOICE_TOOLS_OPENAI_KEY = modelKey;
          COSMOS_MEMORY_URL = memoryUrl;
          CLAUDE_SUBSCRIPTION_DIRECTSDK_COMMAND = lib.getExe pkgs.claude-code;
        };

        # The memory provider (hermes/memory-plugin): recall for every message, every exchange stored, memory_* tools.
        extraPlugins = [
          memoryPlugin
          vccPlugin
          planModePlugin
          researchRoutingPlugin
        ];
        environmentFiles = [ config.sops.templates."hermes.env".path ];

        extraPackages = [
          # Converts audio for voice messages.
          pkgs.ffmpeg-headless
          # The Claude plugin sends every request through the official CLI, which holds the login. Log in once as
          # the hermes user: sudo -u hermes -H claude auth login
          pkgs.claude-code
        ];

        # Our tools, each a Rust MCP server over stdio. Hermes names their tools mcp_<server>_<tool>.
        # The Notes vault (its rules: Reference/How this vault works). Reading is free; editing and moving ask the owner
        # first (trust below), since nothing here has an undo.
        mcpServers.notes = vaultServer config.notes.vault "notes" [ ] // {
          tools.exclude = [
            "create"
            "file_note"
            "discard_note"
          ];
        };
        # New notes go in its Inbox without asking: they never replace a note, and the owner reviews the inbox.
        mcpServers.inbox = vaultServer config.notes.vault "notes" [ "--create-only" ] // {
          tools.include = [ "create" ];
        };
        # Filing the Notes inbox, for the nightly job when nobody is there to ask. The owner's review mark is the
        # approval: file_note refuses a note still marked pending and discard_note deletes only one marked delete.
        mcpServers.filing = vaultServer config.notes.vault "notes" [ "--filing" ] // {
          tools.include = [
            "file_note"
            "discard_note"
          ];
        };
        # Research reports go into the Notes vault's Wiki folder: the notes tool reads and searches the whole vault but
        # can only add new notes there, never change one, so it needs no approval.
        mcpServers.wiki = vaultServer config.notes.vault "notes" [
          "--inbox"
          "Wiki"
          "--create-only"
        ];
        # The campaigns vault (D&D 5e 2024 homebrew: Worlds/ and Campaigns/), split the same way: new notes in its inbox
        # freely, edits and moves asked for.
        mcpServers.campaigns = vaultServer campaignsVault "notes-campaigns" [ ] // {
          tools.exclude = [ "create" ];
        };
        mcpServers.campaign_inbox = vaultServer campaignsVault "notes-campaigns" [ "--create-only" ] // {
          tools.include = [ "create" ];
        };
        mcpServers.art = {
          command = lib.getExe art;
          args = [
            "--models"
            models
            "--lora"
            "${imageLora}:1"
            "--dir"
            "${cfg.stateDir}/art"
          ];
        };

        # Who Hermes is here. The repo owns this file; Hermes' own notes go in its skills and memory.
        hermesHomeFiles."SOUL.md" = ./hermes/SOUL.md;

        settings = {
          # main: Ornith 35B on the 7900 XT, always thinking (tool calls go wrong without it). 262K context shared by
          # two slots, so 131K a conversation. Ornith doesn't read images here; the vision role does.
          model = {
            provider = "custom";
            base_url = models;
            api_key = modelKey;
            default = "main";
            context_length = 131072;
            supports_vision = false;
          };

          # Subagents run on main too, so no model swap. Research goes to Claude instead (research-routing).
          delegation = {
            model = "main";
            base_url = models;
            api_key = modelKey;
            backend = "research-routing";
            backends.research-routing = {
              # Everyday research, which uses less of the subscription's allowance.
              model = "sonnet";
              # Deep dives, only when asked for one.
              deep_model = "opus";
            };
          };

          # Compaction by VCC: no model call, so main's slots stay free (it used to spend minutes on a summary).
          context.engine = "vcc";

          # Plugins that aren't model or memory providers load only when listed. The list doesn't merge across files.
          plugins.enabled = [
            "research-routing"
            "hermes-vcc-engine"
            "plan-mode"
            "obsidian"
          ];

          # The decision model approves clearly safe commands. Anything it denies or is unsure about asks the owner.
          approvals.mode = "smart";

          # Untrusted servers ask before every tool not marked read-only; our read tools carry that mark.
          mcp_servers = {
            notes.trust = "untrusted";
            campaigns.trust = "untrusted";
          };

          # Memory is ours (the memory service and its provider plugin), so Hermes' built-in MEMORY.md and USER.md
          # stay off.
          memory = {
            provider = "nix-managed-${lib.getName memoryPlugin}";
            memory_enabled = false;
            user_profile_enabled = false;
          };

          auxiliary = {
            # The helper's 96K is less than a conversation, so main compacts its own chats (as llm.nix says).
            compression = onNabu "main" 900 // {
              # A large summary spends minutes reading its prompt with no streamed output.
              no_progress_timeout = 600;
            };
            title_generation = onNabu "helper" 120;
            background_review = onNabu "helper" 300;
            curator = onNabu "helper" 600;
            vision = onNabu "vision" 120;
            approval = onNabu "decision" 30;
          };

          web.backend = "tavily";

          stt = {
            provider = "openai";
            language = "en";
            openai.model = "transcription";
          };

          # Spoken replies come from nabu's speech model (Qwen3-TTS, a voice designed for Hermes) rather than Hermes'
          # default, which sends the text to Microsoft. The voice is also speech's default.
          tts = {
            provider = "openai";
            openai = {
              base_url = models;
              model = "speech";
              voice = "female-b";
            };
          };
          # Hermes Desktop would otherwise call the speech servers itself.
          voice.client_direct = false;

          # Hermes' own Chromium download can't run on NixOS.
          browser.executable_path = lib.getExe pkgs.chromium;

          dashboard.public_url = publicUrl;
        };
      };
    };

  # Hermes Desktop on a workstation, connected to lugh's backend.
  flake.modules.nixos.hermes-desktop =
    { config, pkgs, ... }:
    {
      sops.secrets.hermes-desktop-token = {
        sopsFile = ../../secrets/common.yaml;
        owner = "twins";
      };

      environment.systemPackages = [
        # The token is read at launch, because anything passed as extraEnv ends up in the Nix store.
        (inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.desktop.override {
          extraEnv.HERMES_DESKTOP_REMOTE_URL = publicUrl;
          extraRun = [
            ''export HERMES_DESKTOP_REMOTE_TOKEN="$(< ${config.sops.secrets.hermes-desktop-token.path})"''
          ];
        })
      ];
    };
}
