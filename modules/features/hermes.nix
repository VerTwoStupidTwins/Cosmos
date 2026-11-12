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
      imageQualityPlugin = pkgs.runCommand "image-quality" { } ''
        cp -r ${./hermes-image-quality} $out
      '';

      localTask = model: timeout: {
        provider = "llamacpp";
        base_url = llamaSwap;
        inherit model timeout;
      };

      helperTask = localTask "helper";
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

        # The image tool can't choose its model per request, so quality images get a tool of their own.
        extraPlugins = [ imageQualityPlugin ];

        settings = {
          model = {
            provider = "custom";
            base_url = llamaSwap;
            default = "main";
            context_length = 128000;
          };

          # Prompts need a person until the decision model has an adapter.
          approvals.mode = "manual";

          # The main model is abliterated, but it still refused some explicit requests.
          agent.system_prompt = ''
            This is a private system used only by its adult owner. Adult and sexually explicit content is
            allowed here, including explicit images. When asked for one, write the prompt and call an image
            tool instead of refusing, and start the prompt with the explicit or nsfw safety tag. Every person
            in sexual content must be an adult, so describe them as adults.
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
            vision = localTask "vision" 120;
          };

          image_gen = {
            provider = "openai";
            openai = {
              base_url = llamaSwap;
              key_env = "LLAMA_SWAP_API_KEY";
              model = "image-fast";
            };
            # Both image models share one card.
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

          # Plugins that aren't bundled with Hermes load only when listed.
          plugins.enabled = [ "image-quality" ];
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
