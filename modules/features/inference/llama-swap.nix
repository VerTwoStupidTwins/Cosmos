# Native model-switching control plane; hosts select backends and model rosters.
{ config, ... }:
{
  flake.modules.nixos."llama-swap" =
    { lib, ... }:
    {
      services.llama-swap = {
        enable = true;
        listenAddress = lib.mkDefault "127.0.0.1";
        port = lib.mkDefault 8081;
        openFirewall = lib.mkDefault false;
        settings = {
          healthCheckTimeout = lib.mkDefault 300;
          globalTTL = lib.mkDefault 600;
          unloadTimeout = lib.mkDefault 30;
          logToStdout = lib.mkDefault "proxy";
          # Shared testing does not require retaining request/response bodies.
          captureBuffer = lib.mkDefault 0;
        };
      };
      systemd.services.llama-swap.serviceConfig = {
        SupplementaryGroups = [ "render" ];
        KillMode = "control-group";
        TimeoutStopSec = 60;
      };
    };

  perSystem = { pkgs, ... }: {
    checks.odin-llama-swap = import ../../../tests/odin-llama-swap.nix {
      inherit pkgs;
      odin = config.flake.nixosConfigurations.odin.config;
    };
  };
}
