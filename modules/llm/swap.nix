# modules/llm/swap.nix
#
# llama-swap in front of the host's llama.cpp backends (nixos.llama-cuda, -rocm, -sycl, -vulkan). A host lists its
# models under llm.models, each with the backend it runs on and its llama-server flags, and this module gives each
# one that backend's build and environment. A model can instead be any program that serves the same kind of API,
# such as whisper-server or an adapter in front of another model, given as a command. Clients ask for a model by name, so a name can stand for a role, such
# as "main", and the model behind it can change without touching them.
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

      # The systemd units a model's cards need: its backend's, or those its command lists.
      unitsOf =
        model: if model.backend != null then config.llama.backends.${model.backend}.units else model.units;

      entry =
        name: model:
        let
          backend = config.llama.backends.${model.backend};
          llamaServer = lib.concatStringsSep " " (
            [
              (lib.getExe' backend.package "llama-server")
              "--host 127.0.0.1"
              "--port \${PORT}"
            ]
            ++ model.args
          );
        in
        {
          cmd = if model.backend != null then llamaServer else model.command;
          env = lib.mapAttrsToList (variable: value: "${variable}=${value}") (
            lib.optionalAttrs (model.backend != null) backend.env // model.env
          );
          inherit (model) checkEndpoint;
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
                  type = lib.types.nullOr (lib.types.enum (lib.attrNames config.llama.backends));
                  default = null;
                  example = "cuda";
                  description = "The llama.cpp backend it runs on, from llama.backends. Either this or command.";
                };

                args = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "llama-server's flags, apart from the address and port, which llama-swap chooses.";
                };

                command = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = "whisper-server --host 127.0.0.1 --port \${PORT} -m ggml-large-v3-turbo-q8_0.bin";
                  description = ''
                    A program to run instead of llama-server, for a model llama.cpp doesn't serve. It must listen on
                    127.0.0.1 at the port llama-swap puts in its place of ''${PORT}. Either this or backend.
                  '';
                };

                units = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = ''
                    For a command: the systemd units its cards need, as a backend's units. A llama.cpp model takes
                    its backend's.
                  '';
                };

                path = lib.mkOption {
                  type = lib.types.listOf lib.types.package;
                  default = [ ];
                  description = "Programs its command calls, added to llama-swap's PATH.";
                };

                checkEndpoint = lib.mkOption {
                  type = lib.types.str;
                  default = "/health";
                  description = "What llama-swap polls until it answers, to know the model has loaded.";
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
            units = lib.unique (lib.concatMap unitsOf (lib.attrValues cfg.models));
          in
          {
            after = units;
            wants = units;
            path = lib.concatMap (model: model.path) (lib.attrValues cfg.models);
          };

        assertions = lib.mapAttrsToList (name: model: {
          assertion = (model.backend == null) != (model.command == null);
          message = "llm.models.${name} needs either a backend or a command, not both.";
        }) cfg.models;

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
