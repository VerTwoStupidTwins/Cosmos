{ ... }:
{
  flake.nixosModules.zram = { ... }: {
    zramSwap = {
      enable = true;
      algorithm = "zstd";
      memoryPercent = 50;
      swapDevices = 1;
      priority = 100;
    };
    swapDevices = [ ];
  };
}
