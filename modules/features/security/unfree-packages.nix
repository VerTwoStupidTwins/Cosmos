# Compose narrow package-license exceptions without replacing another profile.
{
  flake.modules.nixos.base = { config, lib, ... }: {
    options.cosmos.allowedUnfreePackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Explicit unfree package names allowed by imported profiles.";
    };
    config.nixpkgs.config.allowUnfreePredicate =
      pkg: builtins.elem (lib.getName pkg) config.cosmos.allowedUnfreePackages;
  };
}
