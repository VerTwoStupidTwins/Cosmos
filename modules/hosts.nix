{
  config,
  inputs,
  lib,
  ...
}:
{
  options.hosts = lib.mkOption {
    type = lib.types.lazyAttrsOf lib.types.deferredModule;
    default = { };
  };

  config.flake.nixosConfigurations = lib.mapAttrs (
    name: module:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        config.flake.modules.nixos.base
        module
        { networking.hostName = name; }
      ];
    }
  ) config.hosts;
}
