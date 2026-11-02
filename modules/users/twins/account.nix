{ self, ... }:

{
  flake.nixosModules.twins =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      sops.secrets."twins-password-hash" = {
        sopsFile = ../../../secrets/shared.yaml;
        neededForUsers = true;
      };

      users.users.twins = {
        isNormalUser = true;
        home = "/home/twins";
        shell = pkgs.fish;
        hashedPasswordFile = config.sops.secrets."twins-password-hash".path;

        # Administrative access on every host.
        extraGroups = [
          "wheel"
        ]
        ++ lib.optionals config.networking.networkmanager.enable [
          "networkmanager"
        ];
      };

      # Import twins' shared Home Manager configuration.
      home-manager.users.twins.imports = [
        self.homeModules.twins
      ];

      users.users.twins.openssh.authorizedKeys.keyFiles = [
        ../../../keys/ssh/thoth.pub
      ];

      users.users.twins.openssh.authorizedKeys.keys = [
        # Phone - Termius
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAlyX2kejnl4VEhT7pwvfmp5ZWr64+V4a9zg582/UjtX phone-termius"

        # Thoth - Cosmos administrator
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHwR9vWQS5IXipAItMIR4bGScZMxcLKamapXntnK1g1O cosmos-admin-thoth"
      ];

    };
}
