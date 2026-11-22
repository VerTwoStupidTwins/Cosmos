{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  # The homelab's infrastructure server: it watches every host (metrics, logs, dashboards, alerts to the phone through
  # ntfy), runs the homelab's Matrix server and its agent (with its memory's Qdrant), and builds for the others and keeps
  # their builds in the binary cache. Game streaming from the
  # B580 and modded Minecraft and Foundry VTT servers come later, all over NetBird.
  hosts.lugh = {
    topology.self.hardware.info = "AMD Ryzen 9 5900X, 64 GB, Arc B580; infrastructure server";
    imports = [
      nixos.systemd-boot
      nixos.server
      nixos.builder
      nixos.binary-cache
      nixos.cache-push
      nixos.monitor
      nixos.web
      nixos.ntfy
      nixos.matrix
      nixos.agent
      nixos.memory-store
      nixos.shared-nas
      nixos.observability
      nixos.observed
    ];

    # The desktop bar's homelab plate reads lugh's monitor.
    monitor.allowStation = true;

    nixpkgs.hostPlatform = "x86_64-linux";
    hardware.facter.reportPath = ./facter.json;
    system.stateVersion = "26.05";
  };
}
