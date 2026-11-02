{ ... }:
{
  flake.nixosModules.secureBoot = { pkgs, ... }: {
    boot.loader = {
      systemd-boot = {
        enable = false;
        editor = false;
      };

      efi.canTouchEfiVariables = true;
    };

    boot.lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
      configurationLimit = 6;
    };

    environment.systemPackages = [
      pkgs.sbctl
    ];
  };
}
