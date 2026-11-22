{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  # A Lenovo ThinkPad C13 Yoga Chromebook (Google "Morphius") with MrChromebox's UEFI firmware.
  # The main workstation; the touchscreen and stylus are for drawing and media work.
  hosts.tenjin = {
    topology.self.hardware.info = "ThinkPad C13 Yoga (convertible Chromebook); main workstation";
    imports = [
      nixos.systemd-boot
      nixos.laptop
      nixos.convertible
      nixos.snapshots
      nixos.desktop
      nixos.niri
      nixos.build-client
      nixos.deploy
      nixos.cache-push
      nixos.cache-pull
      nixos.claude-code
      nixos.krita
      nixos.monitor-station
      nixos.netbird-api
      nixos.observed
    ];

    nixpkgs.hostPlatform = "x86_64-linux";
    hardware.facter.reportPath = ./facter.json;
    system.stateVersion = "26.05";

    boot.initrd.services.lvm.enable = true;
  };
}
