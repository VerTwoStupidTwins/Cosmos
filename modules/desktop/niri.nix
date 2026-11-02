{ self, ... }:
{
  flake.nixosModules.niri = { ... }: {
    imports = [
      self.nixosModules.desktopUsability
      self.nixosModules.session
    ];

    programs.niri = {
      enable = true;
      useNautilus = false;
    };

    security.rtkit.enable = true;

    services.pipewire = {
      enable = true;
      alsa.enable = true;
      jack.enable = true;
      pulse.enable = true;
      wireplumber.enable = true;
    };
  };

  flake.homeModules.niri = {pkgs, ... }: {
    imports = [
      self.homeModules.session
      self.homeModules.appearance
      self.homeModules.desktopUsability
      self.homeModules.screenshots
    ];

    home.packages = with pkgs; [
      firefox
      kitty
      waybar
      wofi
      mako
      thunar
      yazi
      xwayland-satellite
      brightnessctl
    ];

    services.polkit-gnome.enable = true;

    xdg.configFile."niri/config.kdl".source = ./niri-config.kdl;

  };
}
