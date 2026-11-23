# modules/base/dix.nix
# nh diffs a host deployed from elsewhere (rebuild-<host>, modules/features/deploy.nix) with dix on that host, and
# skips the diff without it.
{
  flake.modules.nixos.base =
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.dix ];
    };
}
