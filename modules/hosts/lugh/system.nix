{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  # The old LLM server, now that nabu has taken over its models: a minimal host until its next job is decided. It
  # still builds for the other hosts, and tenjin's homelab plate still checks on it.
  hosts.lugh = {
    imports = [
      nixos.systemd-boot
      nixos.server
      nixos.builder
      nixos.monitor
    ];

    # The desktop bar's homelab plate reads lugh's monitor.
    monitor.allowStation = true;

    nixpkgs.hostPlatform = "x86_64-linux";
    hardware.facter.reportPath = ./facter.json;
    system.stateVersion = "26.05";
  };
}
