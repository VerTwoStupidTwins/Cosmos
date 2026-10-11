{
  flake.modules.nixos.base = {
    services.resolved.enable = true;

    services.netbird.clients.wt0 = {
      port = 58120;
      interface = "wto";

      hardened = true;
      autoStart = true;

      openFirewall = true;
      openInternalFirewall = true;
    };
  };
}
