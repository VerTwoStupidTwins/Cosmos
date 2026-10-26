# Shared applications and file-manager integrations; no user configuration.
{
  flake.modules.nixos."base-desktop" = { pkgs, ... }: {
    # The official client has both an FHS wrapper and an unwrapped payload.
    cosmos.allowedUnfreePackages = [
      "discord"
      "discord-unwrapped"
    ];

    services = {
      gvfs.enable = true;
      udisks2.enable = true;
      tumbler.enable = true;
    };

    fonts.packages = [
      pkgs.nerd-fonts.monoid
      (pkgs.google-fonts.override { fonts = [ "Rajdhani" ]; })
    ];

    environment.systemPackages = with pkgs; [
      # Files and archives.
      thunar
      thunar-archive-plugin
      thunar-volman
      tumbler
      gvfs
      udiskie
      file-roller

      # Audio and video.
      pavucontrol
      crosspipe
      ffmpeg
      mpv
      vlc

      # QML desktop-shell toolkit; no shell configuration or autostart.
      quickshell

      # General workstation applications.
      discord
      telegram-desktop
      firefox
      emacs
      libreoffice
      evince
      imv
      imagemagick
      gnome-keyring

      # CLI-based power and container utilities (services not enabled here).
      tlp
      powertop
      flatpak
      podman
      buildah
      skopeo
    ];
  };
}
