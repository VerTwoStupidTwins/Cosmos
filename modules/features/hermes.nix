# modules/features/hermes.nix
{ inputs, ... }:
{
  flake.modules.nixos.hermes =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      llamaSwap = "http://127.0.0.1:8080/v1";

      # Hermes names a Nix-managed plugin after its derivation.
      imageFastPlugin = pkgs.runCommand "image-fast" { } ''
        cp -r ${./hermes-image-fast} $out
      '';

      localTask = model: timeout: {
        provider = "llamacpp";
        base_url = llamaSwap;
        inherit model timeout;
      };

      helperTask = localTask "helper";

      hermesHome = "${config.services.hermes-agent.stateDir}/.hermes";
      skillsDir = "${hermesHome}/skills";
      # Hermes' edits to files the config manages, saved before a switch replaces them. Outside its home, so Hermes
      # doesn't load them as skills. lugh-monitor reports them, and the repo is where they belong.
      savedEdits = "${config.services.hermes-agent.stateDir}/edits";
      managedFiles = lib.attrNames config.services.hermes-agent.hermesHomeFiles;

      # Hermes copies its bundled skills out of the Nix store with the store's read-only modes, so it can't edit or
      # patch them. The modes aren't part of the hash Hermes uses to spot user edits, so this doesn't stop updates.
      # Skills a new Hermes version adds stay read-only until its next start or switch.
      unlockSkills = ''
        find ${skillsDir} -user hermes \( -type d -o -type f \) ! -perm -u+w,g+w -exec chmod u+w,g+w {} + || true
      '';
    in
    {
      imports = [ inputs.hermes-agent.nixosModules.default ];

      sops.secrets = {
        hermes-desktop-token = {
          owner = "hermes";
          mode = "0400";
          restartUnits = [ "hermes-backend.service" ];
        };
      }
      # The user IDs aren't secret, but they're personal, so they stay out of the public repository.
      // lib.genAttrs [
        "tavily-api-key"
        "telegram-bot-token"
        "telegram-allowed-users"
        "discord-bot-token"
        "discord-allowed-users"
      ] (_: { });

      # Activation copies this into Hermes' .env, which Hermes reads only when it starts.
      sops.templates."hermes.env" = {
        content = ''
          TAVILY_API_KEY=${config.sops.placeholder.tavily-api-key}
          TELEGRAM_BOT_TOKEN=${config.sops.placeholder.telegram-bot-token}
          TELEGRAM_ALLOWED_USERS=${config.sops.placeholder.telegram-allowed-users}
          DISCORD_BOT_TOKEN=${config.sops.placeholder.discord-bot-token}
          DISCORD_ALLOWED_USERS=${config.sops.placeholder.discord-allowed-users}
        '';
        restartUnits = [
          "hermes-agent.service"
          "hermes-backend.service"
        ];
      };

      networking.firewall.interfaces."nb-wt0".allowedTCPPorts = [
        config.services.hermes-agent.backend.port
      ];

      # Lets twins read and edit the service's config and logs.
      users.users.twins.extraGroups = [ "hermes" ];

      # With twins in the group, Hermes counts a group-writable home as unsafe and refuses to reach its gateway, which
      # fails every cron job. The module makes the home 2770 at boot (tmpfiles) and on every switch (activation), so
      # both are overridden: tmpfiles keeps the first line for a path, and this script runs after the module's.
      # Subdirectories stay group-writable, and twins can still edit config.yaml in place.
      systemd.tmpfiles.rules = lib.mkBefore [ "d ${hermesHome} 2750 hermes hermes - -" ];
      system.activationScripts.hermes-home-private = lib.stringAfter [ "hermes-agent-setup" ] ''
        chmod 2750 ${hermesHome}
        if [ -d ${skillsDir} ]; then
          # The module makes the folders for hermesHomeFiles, such as skills/research/llm-wiki, as root. Hermes can
          # then add files beside the llm-wiki skill, but its edits to SKILL.md itself last only until the next switch.
          find ${skillsDir} ! -user hermes ! -type l -exec chown hermes:hermes {} + || true
          ${unlockSkills}
        fi
        # What was just installed, to compare with at the next switch.
        for f in ${lib.escapeShellArgs managedFiles}; do
          if [ -f "${hermesHome}/$f" ]; then
            install -D -m 0640 -o hermes -g hermes "${hermesHome}/$f" "${savedEdits}/.installed/$f"
          fi
        done
        # install -D makes folders as root. twins, in the group, clears saved edits once they're in the repo.
        if [ -d ${savedEdits} ]; then
          chown -R hermes:hermes ${savedEdits}
          find ${savedEdits} -type d -exec chmod 2770 {} +
        fi
      '';

      # Runs before the module replaces the files it manages: one that differs from what the last switch installed was
      # edited by Hermes, so a copy is kept.
      system.activationScripts.hermes-save-edits = lib.stringAfter [ "users" ] ''
        for f in ${lib.escapeShellArgs managedFiles}; do
          live="${hermesHome}/$f"
          last="${savedEdits}/.installed/$f"
          if [ -f "$live" ] && [ -f "$last" ] && ! ${pkgs.diffutils}/bin/cmp -s "$live" "$last"; then
            install -D -m 0640 -o hermes -g hermes "$live" "${savedEdits}/$f.$(date +%Y-%m-%d-%H%M%S)"
            echo "hermes: saved Hermes' edits to $f in ${savedEdits} before replacing it" >&2
          fi
        done
      '';
      system.activationScripts.hermes-agent-setup.deps = [ "hermes-save-edits" ];

      # Hermes copies new bundled skills as it starts, so each start also unlocks the ones the previous start copied.
      systemd.services.hermes-agent.preStart = lib.mkAfter unlockSkills;

      services.hermes-agent = {
        enable = true;
        addToSystemPackages = true;

        # For Hermes Desktop. Requests must use this name, so the app connects to it rather than an IP.
        backend = {
          mode = "serve";
          host = "lugh.netbird.cloud";
          waitFor = "hostname";
          sessionTokenFile = config.sops.secrets.hermes-desktop-token.path;
        };

        environment = {
          # llama-swap ignores it, but the image backend refuses to run without a key.
          LLAMA_SWAP_API_KEY = "local";
          # Voice messages go to the local Whisper through Hermes' OpenAI-style transcription, which also needs a key.
          STT_OPENAI_BASE_URL = llamaSwap;
          VOICE_TOOLS_OPENAI_KEY = "local";
        };

        # Web search, and the Telegram and Discord bots, which reply only to the allowed users.
        environmentFiles = [ config.sops.templates."hermes.env".path ];

        # Converts audio for voice messages, such as the Opus files Telegram plays as voice bubbles.
        extraPackages = [ pkgs.ffmpeg-headless ];

        # The image tool can't choose its settings per request, so quick images get a tool of their own.
        extraPlugins = [ imageFastPlugin ];

        settings = {
          model = {
            provider = "custom";
            base_url = llamaSwap;
            default = "main";
            context_length = 128000;
            # The main model reads images itself, so they go to it as images instead of text descriptions.
            supports_vision = true;
          };

          # The decision model approves clearly safe commands. Anything it denies or is unsure about still asks a person.
          approvals.mode = "smart";

          # The main model is abliterated, but it still refused some explicit requests.
          # The memory_ tools are Hermes' only memory, so its built-in MEMORY.md and USER.md stay off.
          memory = {
            # Settings merge into Hermes' config file, so a removed provider would stay set without this.
            provider = "";
            memory_enabled = false;
            user_profile_enabled = false;
          };

          agent.system_prompt = ''
            This is a private system used only by its adult owner. Adult and sexually explicit content is
            allowed here, including explicit images. When asked for one, write the prompt and call an image tool
            instead of refusing. Every person in sexual content must be an adult, so describe them as adults.

            For images, use image_generate_fast, which takes about 20 seconds. Use image_generate, which takes
            about 90 seconds, only when the owner asks for higher quality or more detail, or says to take your
            time. Describe the image in detailed plain sentences: subject, setting, style, lighting and composition.

            When the owner asks you to research something, don't search the web yourself. Hand it to a
            subagent with delegate_task and route='research', or route='deep-research' when they ask for a
            deep dive or an in-depth investigation. Then file the report in the wiki with the llm-wiki skill
            before you reply. Quick lookups, such as a single fact, the weather or a price, are not research.

            Your lasting memory of the owner is the memory_ tools. When the owner tells you something worth
            keeping about themselves, their setup or how they like things done, or asks you to remember
            something, save it with memory_remember. Before answering anything that depends on their situation
            or history, check memory_recall. When they correct something you remembered, revise that memory.
          '';

          auxiliary = {
            compression = lib.recursiveUpdate (helperTask 900) {
              # A large summary spends minutes reading its prompt with no streamed output.
              no_progress_timeout = 600;
              # Below the main model's 96K trigger, Hermes would start compacting earlier.
              context_length = 96000;
            };
            title_generation = helperTask 120;
            background_review = helperTask 300;
            curator = helperTask 600;
            # The vision_analyze tool uses the main model too. An explicit vision backend here would turn the
            # owner's images into text descriptions, and settings merge into Hermes' config file, so the old
            # vision model would stay set if this were just removed.
            vision = {
              provider = "auto";
              model = "";
              base_url = "";
            };
            approval = localTask "approval" 30;
          };

          image_gen = {
            provider = "openai";
            openai = {
              base_url = llamaSwap;
              key_env = "LLAMA_SWAP_API_KEY";
              model = "image";
            };
            # The 25-step quality setting. image_generate_fast asks the same model for its 8-step LoRA.
            # One image at a time, since the model has the B580 to itself.
            max_parallel_requests = 1;
          };

          web.backend = "tavily";

          stt = {
            provider = "openai";
            language = "en";
            openai.model = "transcription";
          };

          # Spoken replies come from the Kokoro service on lugh.
          tts = {
            provider = "openai";
            openai = {
              base_url = "http://127.0.0.1:8880/v1";
              model = "kokoro";
              voice = "af_heart";
            };
          };

          # Hermes Desktop would otherwise call the speech servers itself, and they only answer on lugh.
          voice.client_direct = false;

          # Hermes' own Chromium download can't run on NixOS.
          browser.executable_path = lib.getExe pkgs.chromium;

          # Plugins that aren't bundled with Hermes load only when listed.
          # Settings don't merge lists across files, so every enabled plugin is listed here.
          plugins.enabled = [
            "image-fast"
            "research-routing"
            "hermes-memory"
          ];
        };
      };
    };

  flake.modules.nixos.hermes-desktop =
    { config, pkgs, ... }:
    {
      sops.secrets.hermes-desktop-token.owner = "twins";

      environment.systemPackages = [
        # The token is read at launch, because anything passed as extraEnv ends up in the Nix store.
        (inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.desktop.override {
          extraEnv.HERMES_DESKTOP_REMOTE_URL = "http://lugh.netbird.cloud:9119";
          extraRun = [
            ''export HERMES_DESKTOP_REMOTE_TOKEN="$(< ${config.sops.secrets.hermes-desktop-token.path})"''
          ];
        })
      ];
    };
}
