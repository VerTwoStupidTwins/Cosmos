# modules/base/monitor.nix
{
  # What a host is meant to be running, declared by the modules that set it up. lugh-monitor compares it with what
  # is running. Declared on every host so any module can fill it in; only hosts with the monitor read it.
  flake.modules.nixos.base =
    { lib, ... }:
    let
      inherit (lib) mkOption types;
    in
    {
      options.monitor = {
        units = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Services that should be active. The monitor shows logs from these only.";
        };

        ports = mkOption {
          type = types.attrsOf types.port;
          default = { };
          description = "TCP ports that should be listening, by what listens on them.";
        };

        cards = mkOption {
          type = types.attrsOf (
            types.submodule {
              options = {
                name = mkOption {
                  type = types.str;
                  description = "The card's full name.";
                };
                pciId = mkOption {
                  type = types.str;
                  example = "0x1002:0x744c";
                  description = "Vendor and device ID, which stay the same when cards change slots.";
                };
                note = mkOption {
                  type = types.str;
                  default = "";
                  description = "What its role list can't say on its own.";
                };
              };
            }
          );
          default = { };
          description = "GPUs by short name, which is also how llama-server --list-devices names them.";
        };

        models = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Which card, by short name, each model runs on. Together these are each card's role.";
        };

        llamaServer = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "llama-server, whose --list-devices gives each card's free memory.";
        };

        llamaSwapUrl = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "llama-swap's address, for which models are loaded.";
        };

        memorySocket = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The memory service's socket, on the host Hermes runs on.";
        };

        allowHermes = mkOption {
          type = types.bool;
          default = false;
          description = "Let Hermes, from another host, run this host's monitor over SSH, and nothing else.";
        };

        command = mkOption {
          type = types.listOf types.str;
          readOnly = true;
          description = "The monitor's command line on this host, set by the monitor module.";
        };

        checkDevices = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "A script that fails, explaining why, if devices are numbered differently than the models expect.";
        };
      };
    };
}
