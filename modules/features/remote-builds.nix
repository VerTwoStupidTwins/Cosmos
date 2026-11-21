# modules/features/remote-builds.nix
let
  # Each builder signs what it builds, so its results can be copied to other hosts, as nh does after a --build-host
  # build. The secret halves are in each host's own sops file, which only that host can read.
  signingKeys = [
    "kobold-1:+NX7E2USSlLQtfcsv/MIZJ2Sv9N4ZvD6TRu4N5TSdFg="
    "lugh-1:+52KriMOQOPLuLMtk9vztdoCj+251rflRHzyffMRsfI="
  ];
in
{
  flake.modules.nixos.builder =
    { config, ... }:
    {
      sops.secrets.nix-signing-key.sopsFile = ../../secrets/${config.networking.hostName}.yaml;
      nix.settings.secret-key-files = [ config.sops.secrets.nix-signing-key.path ];
      # Builders take each other's builds too, so one can build the other's system (nh --build-host lugh
      # --target-host kobold) and copy it straight across.
      nix.settings.trusted-public-keys = signingKeys;

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

      nix.settings.trusted-public-keys = signingKeys;

      nix.distributedBuilds = true;
      nix.settings.builders-use-substitutes = true;

      # Nix gives each job to the machine with the least work for its speed factor, so kobold takes the builds and
      # lugh only gets them when kobold is busy or down.
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
            # kobold is out until its memory corruption is fixed (2026-11-17): it damaged files in its own store, so
            # what it builds can't be trusted. Put this back after a clean memtest and a reinstall.
            # {
            #   hostName = "kobold.netbird.cloud";
            #   maxJobs = 10;
            #   speedFactor = 16;
            # }
            {
              hostName = "lugh.netbird.cloud";
              maxJobs = 12;
              speedFactor = 1;
            }
          ];
    };
}
