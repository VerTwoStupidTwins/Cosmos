# modules/features/krita.nix
{
  # Krita, for drawing with the pen. Its AI Diffusion plugin drew through lugh's ComfyUI, which is off now that lugh
  # is being repurposed; comfyui.nix is still there for whichever host takes it on.
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
