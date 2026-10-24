{
  flake.modules.nixos."nvidia-headless" = { pkgs, ... }: {
    # Narrow exception for NVIDIA userspace; no global allowUnfree/CUDA rebuilds.
    cosmos.allowedUnfreePackages = [ "nvidia-x11" ];

    hardware = {
      graphics.enable = true;
      nvidia = {
        # The RTX A2000 is Ampere and supports NVIDIA's open kernel modules.
        open = true;
        nvidiaSettings = false;
        nvidiaPersistenced = true;
      };
    };
    # This selects the driver; it does not enable X11 or a desktop session.
    services.xserver.videoDrivers = [ "nvidia" ];
    environment.systemPackages = [ pkgs.pciutils ];
  };
}
