{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  # A Lenovo ThinkPad C13 Yoga Chromebook (Google "Morphius") with MrChromebox's UEFI firmware.
  # It mirrors thoth for now; the touchscreen and stylus are for drawing and media work.
  hosts.tenjin = {
    imports = [
      nixos.systemd-boot
      nixos.laptop
      nixos.snapshots
      nixos.desktop
      nixos.hyprland
      nixos.build-client
      nixos.claude-code
      nixos.hermes-desktop
      nixos.krita
    ];

    nixpkgs.hostPlatform = "x86_64-linux";
    hardware.facter.reportPath = ./facter.json;
    system.stateVersion = "26.05";

    boot.initrd.services.lvm.enable = true;
  };
}
