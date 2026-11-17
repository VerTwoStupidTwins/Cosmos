{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  # The infrastructure server: an Intel Core Ultra 7 265K desktop with 32 GB of RAM. It's meant for the services
  # that should stay up whatever happens to lugh (Matrix first), Nix builds, and the Minecraft and Foundry VTT servers.
  hosts.kobold = {
    imports = [
      nixos.systemd-boot
      nixos.server
      nixos.builder
    ];

    nixpkgs.hostPlatform = "x86_64-linux";
    hardware.facter.reportPath = ./facter.json;
    system.stateVersion = "26.11";
  };
}
