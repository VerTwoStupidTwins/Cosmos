{
  # NetBird decides who reaches what on the mesh. Its client accepts traffic its access policies allow before the
  # NixOS firewall sees it (and drops what they don't), so the nb-wt0 rules in the modules only apply if NetBird's
  # firewall handling is off. The groups and policies, with why each exists, are declared in modules/netbird-policies.nix
  # (and checked against the dashboard by the agent's drift check). A service that another host or the phone must reach
  # needs a policy there as well as its own config.
  flake.modules.nixos.base =
    { lib, ... }:
    {
      services.netbird.clients.wt0 = {
        port = 51821;
        ui.enable = lib.mkDefault false;
        openFirewall = true;
        openInternalFirewall = true;
      };

      services.resolved.enable = true;
    };
}
