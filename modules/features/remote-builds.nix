# modules/features/remote-builds.nix
{
  flake.modules.nixos.builder = {
    nix.sshServe = {
      enable = true;
      protocol = "ssh-ng";
      write = true;
      trusted = true;
      keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzNYKxXW4zC6fUZHoN31tyx43Jxar8iGKqBtx/Azf4e nix-builder" ];
    };
  };

  flake.modules.nixos.build-client =
    { config, ... }:
    {
      sops.secrets.builder-key = { };

      programs.ssh.knownHosts.lugh = {
        hostNames = [ "lugh.netbird.cloud" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOW2xA+/CR6trd2iH4bdORyeIjswgoLc8ZglHjEyOeCD";
      };

      nix.distributedBuilds = true;
      nix.settings.builders-use-substitutes = true;

      nix.buildMachines = [
        {
          hostName = "lugh.netbird.cloud";
          system = "x86_64-linux";
          protocol = "ssh-ng";
          sshUser = "nix-ssh";
          sshKey = config.sops.secrets.builder-key.path;
          maxJobs = 12;
          speedFactor = 4;
          supportedFeatures = [ "nixos-test" "big-parallel" "kvm" "benchmark" ];
        }
      ];
    };
}
