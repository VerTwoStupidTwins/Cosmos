# modules/features/krita.nix
{
  # Krita, for drawing with the pen.
  flake.modules.nixos.krita =
    { pkgs, ... }:
    {
      home-manager.sharedModules = [
        {
          home.packages = [ pkgs.krita ];
        }
      ];
    };
}
