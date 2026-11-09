{
  flake.modules.nixos.desktop = { config, pkgs, ... }:
  {
    security.rtkit.enable = true;

    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
      jack.enable = true;
      wireplumber.enable = true;
    };

    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };
  };
}
