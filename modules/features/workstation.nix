# Common workstation services. Cosmetic configuration is deferred.
{
  flake.modules.nixos.workstation = {
    networking.networkmanager.enable = true;
  };
}
