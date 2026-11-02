{ config, ... }:

{
  # Decrypt using Thoth's SSH host identity.
  sops.age.sshKeyPaths = [
    "/etc/ssh/ssh_host_ed25519_key"
  ];

  # Private SSH client identity.
  sops.secrets."twins-ssh" = {
    sopsFile = ../../secrets/thoth.yaml;
    key = "ssh_private_key";

    owner = "twins";
    group = "users";
    mode = "0400";
  };

  # Keys permitted to log into Thoth.
  users.users.twins.openssh.authorizedKeys.keyFiles = [
    ../../keys/ssh/thoth.pub
  ];

  # Trust Thoth's verified SSH server identity.
  programs.ssh.knownHosts.thoth = {
    hostNames = [
      "thoth"
      "thoth.home.arpa"
      "localhost"
      "127.0.0.1"
    ];

    publicKeyFile = ../../keys/ssh/hosts/thoth.pub;
  };

  # Persistent user SSH agent.
  home-manager.users.twins.services.ssh-agent.enable = true;

  # Thoth's SSH client configuration.
  home-manager.users.twins.programs.ssh.settings.thoth = {
    HostName = "thoth.home.arpa";
    User = "twins";

    IdentityFile = config.sops.secrets."twins-ssh".path;
    IdentitiesOnly = true;

    StrictHostKeyChecking = "yes";
  };
}
