{
  # NetBird decides who reaches what on the mesh. Its client accepts traffic its access policies allow before the
  # NixOS firewall sees it (and drops what they don't), so the nb-wt0 rules in the modules only apply if NetBird's
  # firewall handling is off. NetBird policies only ever allow, and any one of them is enough, so no broad policy
  # (NetBird's default "All", or a group-wide all-to-all) may cover these hosts. The ones to set in the dashboard:
  #
  #   Groups, prefixed with Cosmos so they stand apart from the others' on the shared NetBird account:
  #   CosmosAdmin = tenjin, phone · CosmosServers = lugh, nabu · CosmosWatched = lugh, nabu, tenjin · CosmosInfra = lugh
  #
  #   CosmosAdmin   → CosmosServers  all                   SSH, remote builds, the homelab plate, Grafana, ntfy
  #   CosmosInfra   → CosmosWatched  TCP 9100, 9633, 9835  Prometheus scraping the exporters (observed.nix)
  #   CosmosInfra   → CosmosServers  ICMP                  blackbox ping probes (observability.nix)
  #   CosmosWatched → CosmosInfra    TCP 3100              Alloy pushing journals to Loki
  #   CosmosInfra   → CosmosServers  TCP 8080              the agent on lugh using nabu's models (CosmosModels)
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
