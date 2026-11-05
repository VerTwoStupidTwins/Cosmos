{ config, ... }:

{
  # The private half is installed before activation by nixos-anywhere.
  # It is also the age identity used by sops-nix on this host.
  sops.age.sshKeyPaths = [
    "/etc/ssh/ssh_host_ed25519_key"
  ];

  # Reuse the passphrase-protected workstation SSH identity during the
  # transition from the old Thoth laptop.
  sops.secrets."twins-ssh" = {
    sopsFile = ../../secrets/iris.yaml;
    key = "ssh_private_key";
    owner = "twins";
    group = "users";
    mode = "0400";
  };

  users.users.twins.openssh.authorizedKeys.keyFiles = [
    ../../keys/ssh/thoth.pub
  ];

  programs.ssh.knownHosts = {
    iris = {
      hostNames = [
        "iris"
        "iris.home.arpa"
      ];
      publicKeyFile = ../../keys/ssh/hosts/iris.pub;
    };

    thoth = {
      hostNames = [
        "thoth"
        "thoth.home.arpa"
      ];
      publicKeyFile = ../../keys/ssh/hosts/thoth.pub;
    };
  };

  home-manager.users.twins.services.ssh-agent.enable = true;

  home-manager.users.twins.programs.ssh.settings = {
    thoth = {
      HostName = "thoth.home.arpa";
      User = "twins";
      IdentityFile = config.sops.secrets."twins-ssh".path;
      IdentitiesOnly = true;
      StrictHostKeyChecking = "yes";
    };

    kawiil = {
      User = "twins";
      IdentityFile = "/home/twins/.ssh/id_ed25519_cosmos_admin";
      IdentitiesOnly = true;
    };
  };
}
