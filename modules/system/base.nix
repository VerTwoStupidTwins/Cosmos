{ self, ... }:
{
  flake.nixosModules.base = { pkgs, ... }: {
    imports = [
      # Shared system services
      self.nixosModules.homeManagerDefaults
      self.nixosModules.zram

      # Shared admin user
      self.nixosModules.twins

      self.nixosModules.netbird
    ];

    boot = {
      kernelPackages = pkgs.linuxPackages_latest;
      supportedFilesystems = [ "bcachefs" ];
    };

    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
    networking.networkmanager.enable = true;
    programs.fish.enable = true;
    services.openssh.enable = true;
    time.timeZone = "America/Los_Angeles";
    i18n.defaultLocale = "en_US.UTF-8";
    system.stateVersion = "26.05";
    environment.systemPackages = with pkgs; [
      eza
      neovim
      tree
      git
    ];
  };
}
