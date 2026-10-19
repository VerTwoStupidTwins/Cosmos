{
  flake.modules.nixos.base = {
    services.resolved.enable = true;

    services.netbird.clients.wt0 = {
      port = 58120;
      interface = "wt0";

      hardened = true;
      autoStart = true;

      # Use OpenSSH over the VPN, not NetBird's embedded JWT-authenticated server.
      config.ServerSSHAllowed = false;

      openFirewall = true;
      openInternalFirewall = true;
    };
  };
}
