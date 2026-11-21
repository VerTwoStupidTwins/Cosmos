{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  # The old LLM server, now that nabu has taken over its models. Its next job is game streaming from the B580 and
  # modded Minecraft and Foundry VTT servers, all over NetBird; for now it's a base install that still builds for the
  # other hosts, and tenjin's homelab plate still checks on it.
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
