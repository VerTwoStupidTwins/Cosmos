# modules/base/monitor.nix
{
  # What a host is meant to be running, declared by the modules that set it up. The host monitor compares it with what
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

        command = mkOption {
          type = types.listOf types.str;
          readOnly = true;
          description = "How to run this host's monitor (an MCP server on stdin and stdout), for whatever talks to it.";
        };

        allowStation = mkOption {
          type = types.bool;
          default = false;
          description = "Let the desktop bar's homelab plate, from tenjin, run this host's monitor over SSH, and nothing else.";
        };

        labCommand = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "On a desktop: a script printing each homelab host's health report, one JSON object per line, for the bar.";
        };
      };
    };
}
