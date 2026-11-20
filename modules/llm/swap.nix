# modules/llm/swap.nix
#
# llama-swap in front of the host's llama.cpp backends (nixos.llama-cuda, -rocm, -sycl, -vulkan). A host lists its
# models under llm.models, each with the backend it runs on and its llama-server flags, and this module gives each
# one that backend's build and environment. Clients ask for a model by name, so a name can stand for a role, such
# as "large", and the model behind it can change without touching them.
{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  flake.modules.nixos.llm-swap =
    {
      config,
      lib,
      ...
    }:
    let
      cfg = config.llm;

      entry =
        name: model:
        let
          backend = config.llama.backends.${model.backend};
        in
        {
          cmd = lib.concatStringsSep " " (
            [
              (lib.getExe' backend.package "llama-server")
              "--host 127.0.0.1"
              "--port \${PORT}"
            ]
            ++ model.args
          );
          env = lib.mapAttrsToList (variable: value: "${variable}=${value}") (backend.env // model.env);
        }
        // lib.optionalAttrs (model.aliases != [ ]) { inherit (model) aliases; };
    in
    {
      imports = [ nixos.llama ];

      options.llm = {
        port = lib.mkOption {
          type = lib.types.port;
          default = 8080;
          description = "Where llama-swap serves the models' OpenAI-compatible API, on localhost.";
        };

        models = lib.mkOption {
          default = { };
          description = "The models llama-swap serves, by the name clients ask for.";
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                backend = lib.mkOption {
                  type = lib.types.enum (lib.attrNames config.llama.backends);
                  example = "cuda";
                  description = "The llama.cpp backend it runs on, from llama.backends.";
                };

                args = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  description = "llama-server's flags, apart from the address and port, which llama-swap chooses.";
                };

                env = lib.mkOption {
                  type = lib.types.attrsOf lib.types.str;
                  default = { };
                  description = "Environment on top of the backend's own.";
                };

                aliases = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Other names clients can ask for it by.";
                };

                preload = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Load it when llama-swap starts, so the first request doesn't wait for it to load.";
                };
              };
            }
          );
        };
      };

      config = lib.mkIf (cfg.models != { }) {
        # Waits for its models' cards: started before the NVIDIA driver had loaded, llama-server finds no device
        # and the preload fails.
        systemd.services.llama-swap =
          let
            units = lib.unique (
              lib.concatMap (model: config.llama.backends.${model.backend}.units) (lib.attrValues cfg.models)
            );
          in
          {
            after = units;
            wants = units;
          };

        services.llama-swap = {
          enable = true;
          listenAddress = "127.0.0.1";
          inherit (cfg) port;

          settings = {
            # Large models take a minute or more to load.
            healthCheckTimeout = 300;
            models = lib.mapAttrs entry cfg.models;

            # Each model has its own cards, so they all stay loaded side by side instead of swapping.
            # Models that share a card would need a group of their own that swaps.
            routing.router = {
              use = "group";
              settings.groups.loaded = {
                persistent = true;
                swap = false;
                exclusive = false;
                members = lib.attrNames cfg.models;
              };
            };

            hooks.on_startup.preload = lib.attrNames (lib.filterAttrs (_: model: model.preload) cfg.models);
          };
        };
      };
    };
}
