{
  flake.modules.nixos.base = {
    services.openssh = {
      enable = true;
      openFirewall = true;
    };
  };
}
