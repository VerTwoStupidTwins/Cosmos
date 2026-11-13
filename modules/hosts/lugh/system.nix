{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  hosts.lugh = {
    imports = [
      nixos.systemd-boot
      nixos.server
      nixos.builder
      nixos.gpu
      nixos.claude-code
      nixos.llm
      nixos.hermes
    ];

    nixpkgs.hostPlatform = "x86_64-linux";
    hardware.facter.reportPath = ./facter.json;
    system.stateVersion = "26.05";
  };
}
