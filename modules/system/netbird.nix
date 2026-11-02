{ ... }:
{
  flake.nixosModules.netbird = { ... }: {
    services.resolved.enable = true;

    services.netbird.clients.wt0 = {
      port = 51820;
      interface = "wt0";

      hardened = true;
      autoStart = true;

      openFirewall = true;
      openInternalFirewall = false;

      # Use standard OpenSSH over NetBird.
      config.ServerSSHAllowed = false;
    };
  };
}
