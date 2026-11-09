# modules/features/gpu.nix
{
  flake.modules.nixos.gpu =
    { pkgs, ... }:
    {
      hardware.graphics.enable = true;
      environment.systemPackages = with pkgs; [
        vulkan-tools
        nvtopPackages.full
        pciutils
      ];
    };
}
