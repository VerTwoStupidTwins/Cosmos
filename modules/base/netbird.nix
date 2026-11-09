{
  flake.modules.nixos.base = {lib, ...}: {
    services.netbird.clients.wt0 = {
      port = 51821;
      ui.enable = lib.mkDefault false;
      openFirewall = true;
      openInternalFirewall = true;
    };
    
    services.resolved.enable = true;
  };
}
