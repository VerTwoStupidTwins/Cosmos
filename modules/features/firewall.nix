{
  flake.modules.nixos.base = {
    networking.firewall = {
      enable = true;
      allowPing = true;
    };
  };
}
