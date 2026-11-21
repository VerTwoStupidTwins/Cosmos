{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  # The homelab's infrastructure server: it watches every host (metrics, logs, dashboards, alerts to the phone through
  # ntfy), runs the homelab's Matrix server and its agent, and builds for the others. Game streaming from the
  # B580 and modded Minecraft and Foundry VTT servers come later, all over NetBird.
  hosts.lugh = {
    imports = [
      nixos.systemd-boot
      nixos.server
      nixos.builder
      nixos.monitor
      nixos.web
      nixos.ntfy
      nixos.matrix
      nixos.agent
      nixos.observability
      nixos.observed
    ];

    # The desktop bar's homelab plate reads lugh's monitor.
    monitor.allowStation = true;

    # The pretend restart_service, until the approval gate has been checked on the real service. Remove afterwards.
    agent.testTools = true;

    nixpkgs.hostPlatform = "x86_64-linux";
    hardware.facter.reportPath = ./facter.json;
    system.stateVersion = "26.05";
  };
}
