# Applications and utilities from our earlier Niri workstation package list.
# Only installs packages and basic file-manager integrations; no user config.
{
  flake.modules.nixos."niri-desktop" = { pkgs, ... }: {
    services = {
      gvfs.enable = true;
      udisks2.enable = true;
      tumbler.enable = true;
    };

    fonts.packages = [ pkgs.nerd-fonts.monoid ];

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

      # General workstation applications.
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
