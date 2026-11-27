{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  # The homelab's infrastructure server: it watches every host (metrics, logs, dashboards, alerts to the phone through
  # ntfy), runs the homelab's agent (Hermes, with its memory on Qdrant), and builds for the others and keeps
  # their builds in the binary cache. For play: game streaming from the B580 (Wolf) and Foundry VTT, with modded
  # Minecraft servers to come, all over NetBird.
  hosts.lugh = {
    topology.self.hardware.info = "AMD Ryzen 9 5900X, 128 GB, Arc B580; infrastructure server";
    imports = [
      nixos.systemd-boot
      nixos.server
      nixos.builder
      nixos.binary-cache
      nixos.dns
      nixos.identity
      nixos.homepage
      nixos.forgejo
      nixos.foundry
      nixos.wolf
      nixos.notes
      nixos.cache-push
      # Its own cache too: a build nh's cleanup collected comes back as a download, not a rebuild.
      nixos.cache-pull
      nixos.monitor
      nixos.web
      nixos.ntfy
      nixos.hermes
      nixos.memory-store
      nixos.shared-nas
      nixos.budget
      nixos.rss
      nixos.cloud
      nixos.observability
      nixos.internet-monitor
      nixos.observed
    ];

    # Games installed through Wolf (Steam's library and the like) go in the games subvolume, not the system's.
    wolf.stateDir = "/games/wolf";

    # The tabletop vault (D&D campaigns), beside the main notes vault.
    notes.extraVaults = [ "campaigns" ];

    # The desktop bar's homelab plate reads lugh's monitor.
    monitor.allowStation = true;

    nixpkgs.hostPlatform = "x86_64-linux";
    hardware.facter.reportPath = ./facter.json;
    system.stateVersion = "26.05";
  };
}
