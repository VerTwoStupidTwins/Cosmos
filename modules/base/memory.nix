{
  flake.modules.nixos.base = {
    zramSwap = {
      enable = true;
      memoryPercent = 100;
      priority = 100;
    };
  };
}
