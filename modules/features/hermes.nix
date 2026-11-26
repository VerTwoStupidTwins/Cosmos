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

      hermesHome = "${cfg.stateDir}/.hermes";
      skillsDir = "${hermesHome}/skills";

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

      # With twins in the group, Hermes counts a group-writable home as unsafe and refuses to reach its gateway, which
      # fails every cron job. The module makes the home 2770 at boot (tmpfiles) and on every switch (activation), so
      # both are overridden: tmpfiles keeps the first line for a path, and this script runs after the module's.
      systemd.tmpfiles.rules = lib.mkBefore [ "d ${hermesHome} 2750 hermes hermes - -" ];
      system.activationScripts.hermes-home-private = lib.stringAfter [ "hermes-agent-setup" ] ''
        chmod 2750 ${hermesHome}
        ${unlockSkills}
      '';

      # Hermes copies new bundled skills as it starts, so each start also unlocks the ones the previous start copied.
      # The repo carries no skills: they're Hermes' own, kept in its state and changed only by Hermes or the owner.
      # Conversations start with memory's core block, so Hermes waits for the memory service.
      systemd.services.hermes-agent = {
        preStart = lib.mkAfter unlockSkills;
        after = [ "memory.service" ];
        wants = [ "memory.service" ];
      };
      systemd.services.hermes-backend = {
        after = [ "memory.service" ];
        wants = [ "memory.service" ];
      };

      services.hermes-agent = {
        enable = true;
        addToSystemPackages = true;

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
        };

        # The memory provider (hermes/memory-plugin): recall for every message, every exchange stored, memory_* tools.
        extraPlugins = [ memoryPlugin ];
        environmentFiles = [ config.sops.templates."hermes.env".path ];

        # Converts audio for voice messages.
        extraPackages = [ pkgs.ffmpeg-headless ];

        # Who Hermes is here. The repo owns this file; Hermes' own notes go in its skills and memory.
        hermesHomeFiles."SOUL.md" = ./hermes/SOUL.md;

        settings = {
          # main and workhorse are one Ornith 35B process on the 7900 XT: main without thinking, workhorse with it.
          # 262K context shared by two slots, so 131K a conversation. Ornith doesn't read images here; the vision
          # role does.
          model = {
            provider = "custom";
            base_url = models;
            api_key = modelKey;
            default = "main";
            context_length = 131072;
            supports_vision = false;
          };

          # Subagents think: the same process, so no model swap.
          delegation = {
            model = "workhorse";
            base_url = models;
            api_key = modelKey;
          };

          # The decision model approves clearly safe commands. Anything it denies or is unsure about asks the owner.
          approvals.mode = "smart";

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

          # Spoken replies stay on lugh (Piper) rather than Hermes' default, which sends the text to Microsoft.
          tts.provider = "piper";
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
