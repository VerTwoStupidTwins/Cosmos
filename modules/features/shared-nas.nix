# modules/features/shared-nas.nix
# Services on hestia, the NAS shared with the owner's brother, served by lugh's nginx as <name>.gatica.one. lugh reaches
# hestia over NetBird (policy CosmosNasProxy), by the address in modules/netbird-policies.nix. These sites are shared:
# the brother's devices (Olympus, policy CosmosSitesShared) may use them, unlike lugh's own sites.
{ config, ... }:
let
  hestia = config.cosmos.netbird.peers.hestia.ip;
in
{
  flake.modules.nixos.shared-nas = {
    web.sites.jellyfin = {
      upstream = "http://${hestia}:8096";
      healthPath = "/health";
      # Live updates and playback state over WebSockets; streams pass through as they come, and posters and
      # subtitles can be uploaded.
      websockets = true;
      extraConfig = ''
        proxy_buffering off;
        client_max_body_size 20M;
      '';
      homepage = {
        name = "Jellyfin";
        group = "Media";
        icon = "jellyfin.png";
        description = "Movies and shows on hestia";
      };
    };

    # Seerr: media requests, signed in with Jellyfin accounts.
    web.sites.seerr = {
      upstream = "http://${hestia}:5055";
      healthPath = "/api/v1/status";
      homepage = {
        name = "Seerr";
        group = "Media";
        icon = "jellyseerr.png";
        description = "Request movies and shows";
      };
    };
  };
}
