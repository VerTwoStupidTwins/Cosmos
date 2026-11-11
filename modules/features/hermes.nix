# modules/features/hermes.nix
{ inputs, ... }:
{
  flake.modules.nixos.hermes =
    { config, lib, ... }:
    let
      llamaSwap = "http://127.0.0.1:8080/v1";

      localTask = model: timeout: {
        provider = "llamacpp";
        base_url = llamaSwap;
        inherit model timeout;
      };

      helperTask = localTask "helper";
    in
    {
      imports = [ inputs.hermes-agent.nixosModules.default ];

      sops.secrets.hermes-desktop-token = {
        owner = "hermes";
        mode = "0400";
        restartUnits = [ "hermes-backend.service" ];
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

        # llama-swap ignores it, but the image backend refuses to run without a key.
        environment.LLAMA_SWAP_API_KEY = "local";

        settings = {
          model = {
            provider = "custom";
            base_url = llamaSwap;
            default = "main";
            context_length = 128000;
          };

          # Prompts need a person until the decision model has an adapter.
          approvals.mode = "manual";

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
