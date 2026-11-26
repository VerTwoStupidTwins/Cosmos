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
        # Listed in /v1/models as context_length, for clients that size their prompts by it (OpenCode compacts
        # before it runs out; without it, it guesses).
        // lib.optionalAttrs (model.context != null) { capabilities.context = model.context; }
        // lib.optionalAttrs (model.aliases != [ ]) { inherit (model) aliases; }
        # Each setting with a trailing "?", which makes it a default: a request that sets it keeps its own value.
        // lib.optionalAttrs (model.requestDefaults != { }) {
          filters.setParamsByID = lib.mapAttrs' (
            id: settings:
            lib.nameValuePair (if id == name then "\${MODEL_ID}" else id) (
              lib.mapAttrs' (setting: lib.nameValuePair "${setting}?") settings
            )
          ) model.requestDefaults;
        };
    in
    {
      imports = [ nixos.llama ];

      options.llm = {
        port = lib.mkOption {
          type = lib.types.port;
          default = 8080;
          description = "Where llama-swap serves the models' OpenAI-compatible API.";
        };

        openOnMesh = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Serve the API to NetBird peers too, not just localhost. The port opens on nb-wt0 only, and NetBird's
            CosmosModels policy decides which peers get in (modules/base/netbird.nix).
          '';
        };

        models = lib.mkOption {
          default = { };
          description = "The models llama-swap serves, by the name clients ask for.";
          type = lib.types.attrsOf (
            lib.types.submodule (
              submodule:
              let
                model = submodule.config;
              in
              {
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

                  context = lib.mkOption {
                    type = lib.types.nullOr lib.types.ints.positive;
                    # The "-c N" among its llama-server flags: with --kv-unified one request can use all of it.
                    default =
                      let
                        sizes = lib.concatMap (
                          arg:
                          let
                            m = builtins.match "-c ([0-9]+)" arg;
                          in
                          lib.optional (m != null) (lib.toInt (lib.head m))
                        ) model.args;
                      in
                      if sizes == [ ] then null else lib.last sizes;
                    defaultText = lib.literalMD "the `-c` value in `args`, if any";
                    description = "The longest prompt plus answer it takes, in tokens, as told to clients.";
                  };

                  requestDefaults = lib.mkOption {
                    type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
                    default = { };
                    example = lib.literalExpression ''
                      {
                        main.temperature = 1.0;
                        helper = { temperature = 0.3; chat_template_kwargs.enable_thinking = false; };
                      }
                    '';
                    description = ''
                      Request settings by the name a client asks for, applied when the request doesn't carry them.
                      One loaded model can then act differently under each name. A name other than the model's own
                      becomes another name for it, so it isn't listed in aliases as well.
                    '';
                  };

                  preload = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = "Load it when llama-swap starts, so the first request doesn't wait for it to load.";
                  };

                  card = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    example = "7900xt";
                    description = ''
                      A card it shares with other models, by any name they all use. Only one of them is loaded at a
                      time: a request for another unloads the one there and loads the one asked for. Models without
                      a card stay loaded side by side.
                    '';
                  };
                };
              }
            )
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

        # For the homelab map (modules/topology.nix): the API and each model with what runs it.
        topology.self.services.llama-swap = {
          name = "llama-swap";
          icon = "services.ollama";
          info = "OpenAI-compatible API on port ${toString cfg.port}";
          details = lib.mapAttrs (_: model: {
            text = if model.backend != null then "llama.cpp on ${model.backend}" else "own server";
          }) cfg.models;
        };

        assertions = lib.concatLists (
          lib.mapAttrsToList (name: model: [
            {
              assertion = (model.backend == null) != (model.command == null);
              message = "llm.models.${name} needs either a backend or a command, not both.";
            }
            {
              assertion = lib.all (id: !lib.elem id model.aliases) (lib.attrNames model.requestDefaults);
              message = "llm.models.${name}: a name in requestDefaults is already another name for it; drop it from aliases.";
            }
          ]) cfg.models
        );

        services.llama-swap = {
          enable = true;
          # On every address when open to the mesh: binding nb-wt0's address would race the interface at boot, and
          # the firewall opens the port on nb-wt0 only.
          listenAddress = if cfg.openOnMesh then "0.0.0.0" else "127.0.0.1";
          inherit (cfg) port;

          settings = {
            # Large models take a minute or more to load.
            healthCheckTimeout = 300;
            models = lib.mapAttrs entry cfg.models;

            # Models with cards of their own stay loaded side by side. Models that share a card get a group of their own
            # that swaps; it's persistent and not exclusive too, so loading one never unloads anything elsewhere.
            routing.router = {
              use = "group";
              settings.groups =
                let
                  group = members: swap: {
                    persistent = true;
                    inherit swap members;
                    exclusive = false;
                  };
                  shared = lib.groupBy (name: cfg.models.${name}.card) (
                    lib.attrNames (lib.filterAttrs (_: model: model.card != null) cfg.models)
                  );
                in
                {
                  loaded = group (lib.attrNames (lib.filterAttrs (_: model: model.card == null) cfg.models)) false;
                }
                // lib.mapAttrs' (card: members: lib.nameValuePair "card-${card}" (group members true)) shared;
            };

            hooks.on_startup.preload = lib.attrNames (lib.filterAttrs (_: model: model.preload) cfg.models);
          };
        };

        networking.firewall.interfaces."nb-wt0".allowedTCPPorts = lib.mkIf cfg.openOnMesh [ cfg.port ];
      };
    };
}
