# modules/features/remote-builds.nix
{
  flake.modules.nixos.builder = {
    nix.sshServe = {
      enable = true;
      protocol = "ssh-ng";
      write = true;
      trusted = true;
      keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzNYKxXW4zC6fUZHoN31tyx43Jxar8iGKqBtx/Azf4e nix-builder"
      ];
    };
  };

  flake.modules.nixos.build-client =
    { config, ... }:
    {
      sops.secrets.builder-key = { };

      programs.ssh.knownHosts = {
        kobold = {
          hostNames = [ "kobold.netbird.cloud" ];
          publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFsW8D98Mo2cYCc5ijPszxHPy0qBBnpV4bD/Gxb+ki/U";
        };
        lugh = {
          hostNames = [ "lugh.netbird.cloud" ];
          publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOW2xA+/CR6trd2iH4bdORyeIjswgoLc8ZglHjEyOeCD";
        };
      };

      nix.distributedBuilds = true;
      nix.settings.builders-use-substitutes = true;

      # Nix gives each job to the machine with the least work for its speed factor, so kobold takes the builds and
      # lugh, whose CPU and RAM serve the models, only gets them when kobold is busy or down.
      nix.buildMachines =
        map
          (
            machine:
            {
              system = "x86_64-linux";
              protocol = "ssh-ng";
              sshUser = "nix-ssh";
              sshKey = config.sops.secrets.builder-key.path;
              supportedFeatures = [
                "nixos-test"
                "big-parallel"
                "kvm"
                "benchmark"
              ];
            }
            // machine
          )
          [
            {
              hostName = "kobold.netbird.cloud";
              maxJobs = 10;
              speedFactor = 16;
            }
            {
              hostName = "lugh.netbird.cloud";
              maxJobs = 12;
              speedFactor = 1;
            }
          ];
    };
}
