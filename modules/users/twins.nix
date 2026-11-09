{
  flake.modules.nixos.base = { pkgs, config, ... }: {

    sops.secrets.twins-password.neededForUsers = true;

    programs.fish.enable = true;

    users.mutableUsers = false;

    users.users.twins = {
      isNormalUser = true;
      shell = pkgs.fish;
      hashedPasswordFile = config.sops.secrets.twins-password.path;
      extraGroups = [
        "wheel"
        "networkmanager"
      ];

      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKa1QvCU/Rrvh44eY4UZT0qunJkwvNYqt7F5rrK7IJno"
      ];
    };

    home-manager.users.twins = {
      home.stateVersion = "26.05";

      home.sessionVariables.SOPS_AGE_KEY_CMD = "op read op://wjyh7zy4j3dddmx5xw6sk3thpi/sops-admin-age/private_key";

      programs.fish.enable = true;
    };
  };
}
