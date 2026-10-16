# Compositor-independent desktop services and utilities.
# Applications and the Polkit agent extend this profile in sibling modules.
{
  flake.modules.nixos."base-desktop" = { pkgs, ... }: {
    hardware = {
      graphics.enable = true;
      bluetooth.enable = true;
    };

    security = {
      polkit.enable = true;
      rtkit.enable = true;
    };

    programs.dconf.enable = true;

    services = {
      graphical-desktop.enable = true;
      # Preserve the generic session integration previously supplied by Niri.
      xserver.desktopManager.runXdgAutostartIfNone = true;
      gnome.gnome-keyring.enable = true;
      pipewire = {
        enable = true;
        alsa.enable = true;
        pulse.enable = true;
      };
    };

    environment.systemPackages = with pkgs; [
      waybar
      wofi
      fuzzel
      mako
      awww
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
