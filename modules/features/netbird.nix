{
  flake.modules.nixos.base = {
    services.resolved.enable = true;

    services.netbird.clients.wt0 = {
      port = 58120;
      interface = "wt0";

      hardened = true;
      autoStart = true;

      openFirewall = true;
      openInternalFirewall = true;
    };
  };
}
