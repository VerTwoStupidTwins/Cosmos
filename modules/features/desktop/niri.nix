{
  flake.modules.nixos."niri-desktop" = { pkgs, ... }: {
    programs.niri.enable = true;
    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };
    hardware.graphics.enable = true;
    security = {
      polkit.enable = true;
      rtkit.enable = true;
      pam.services.swaylock = { };
    };

    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
    };

    hardware.bluetooth.enable = true;

    environment.systemPackages = with pkgs; [
      waybar
      wofi
      fuzzel  # Niri's unmodified default launcher binding.
      mako
      swayidle
      swaylock-effects
      awww
      xwayland-satellite
      swayosd
      lxqt.lxqt-policykit

      grim
      slurp
      swappy
      wl-clipboard
      wl-clip-persist
      clipse

      brightnessctl
      playerctl
      networkmanagerapplet
      blueman
      wev
      wlr-randr
    ];
  };
}
