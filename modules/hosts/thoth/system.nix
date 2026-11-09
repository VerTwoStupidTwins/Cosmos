{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  hosts.thoth = {
    imports = [
      nixos.systemd-boot
      nixos.laptop
      nixos.snapshots
      nixos.desktop
      nixos.hyprland
      nixos.build-client
    ];

    nixpkgs.hostPlatform = "x86_64-linux";
    hardware.facter.reportPath = ./facter.json;
    system.stateVersion = "26.05";

    boot.initrd.services.lvm.enable = true;
  };
}
