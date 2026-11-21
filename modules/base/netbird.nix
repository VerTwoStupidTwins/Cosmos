{
  # NetBird decides who reaches what on the mesh. Its client accepts traffic its access policies allow before the
  # NixOS firewall sees it (and drops what they don't), so the nb-wt0 rules in the modules only apply if NetBird's
  # firewall handling is off. The policies, set in the NetBird dashboard, with the default "All" policy removed:
  #
  #   Groups:  admin = tenjin, phone · servers = lugh, nabu · watched = lugh, nabu, tenjin · infra = lugh
  #
  #   admin    → servers   all                       SSH, remote builds, the homelab plate, Grafana, ntfy
  #   infra    → watched   TCP 9100, 9633, 9835      Prometheus scraping the exporters (observed.nix)
  #   infra    → servers   ICMP                      blackbox ping probes (observability.nix)
  #   watched  → infra     TCP 3100                  Alloy pushing journals to Loki
  #   admin    → infra     TCP 443                   (covered by admin → servers; listed for the phone)
  #
  # A service that another host or the phone must reach needs a policy here as well as its own config.
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
