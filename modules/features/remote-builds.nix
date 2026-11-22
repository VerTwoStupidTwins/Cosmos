# modules/features/remote-builds.nix
let
  # Each builder signs what it builds, so its results can be copied to other hosts, as nh does after a --build-host
  # build. The secret halves are in each host's own sops file, which only that host can read.
  signingKeys = [
    "lugh-1:+52KriMOQOPLuLMtk9vztdoCj+251rflRHzyffMRsfI="
  ];
in
{
  flake.modules.nixos.builder =
    { config, ... }:
    {
      sops.secrets.nix-signing-key.sopsFile = ../../secrets/${config.networking.hostName}.yaml;
      nix.settings.secret-key-files = [ config.sops.secrets.nix-signing-key.path ];
      # Builders take each other's builds too, so one can build another host's system and copy it straight across.
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

  # A host built on a builder (rebuild-<host>, modules/features/deploy.nix) takes the builder's signed results.
  flake.modules.nixos.build-target.nix.settings.trusted-public-keys = signingKeys;

  flake.modules.nixos.build-client =
    { config, ... }:
    {
      sops.secrets.builder-key = { };

      # The builders' host keys come from modules/base/known-hosts.nix.
      nix.settings.trusted-public-keys = signingKeys;

      nix.distributedBuilds = true;
      nix.settings.builders-use-substitutes = true;

      # With more than one builder, Nix gives each job to the machine with the least work for its speed factor.
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
              hostName = "lugh.netbird.cloud";
              maxJobs = 12;
              speedFactor = 1;
            }
          ];
    };
}
