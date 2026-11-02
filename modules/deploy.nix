{ inputs, self, ... }:

{
  flake.deploy.nodes.kawiil = {
    # Replace this when Kawiil has a stable NetBird/DNS name.
    hostname = "10.77.10.225";

    sshUser = "twins";

    sshOpts = [
      "-i"
      "/home/twins/.ssh/id_ed25519_cosmos_admin"
      "-o"
      "IdentitiesOnly=yes"
      "-o"
      "StrictHostKeyChecking=yes"
    ];

    # Retain password-protected sudo.
    interactiveSudo = true;

    # Start with locally built, signed closures.
    remoteBuild = false;

    # Preserve deployment safety checks.
    autoRollback = true;
    magicRollback = true;

    profiles.system = {
      user = "root";

      path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.kawiil;
    };
  };

  perSystem = { system, ... }: {
    packages.deploy-rs = inputs.deploy-rs.packages.${system}.default;

    checks = inputs.deploy-rs.lib.${system}.deployChecks self.deploy;
  };
}
