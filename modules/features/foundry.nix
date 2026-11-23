# modules/features/foundry.nix
{ inputs, ... }:
{
  # Foundry VTT at foundry.gatica.one on lugh, for the owner's tabletop group. Players reach it over NetBird: their
  # devices join with the Players setup key, and policy CosmosPlayers lets them reach lugh's HTTPS only; it's a shared
  # site, so nginx lets them in here while lugh's other sites answer them 403. Foundry's own accounts (per player, with
  # the admin password for the setup screen) are the sign-in.
  #
  # Foundry can't be downloaded without the owner's login, so each release's Linux zip is added to lugh's store by hand
  # (nix-store --add-fixed sha256 FoundryVTT-Linux-<version>.zip), with a GC root next to it so it survives cleanups.
  # The license key and admin password are entered once on the setup screen and kept in the data directory.
  flake.modules.nixos.foundry =
    { pkgs, ... }:
    let
      port = 30000;
    in
    {
      imports = [ inputs.foundryvtt.nixosModules.foundryvtt ];

      services.foundryvtt = {
        enable = true;
        # The latest stable v14, built from the flake's recipe with this system's packages (which allow unfree ones;
        # the flake's own set doesn't).
        package = (pkgs.callPackage "${inputs.foundryvtt}/pkgs/foundryvtt" { }).overrideAttrs {
          majorVersion = "14";
          releaseType = "stable";
        };
        hostName = "foundry.gatica.one";
        inherit port;
        # Behind nginx, which serves it over HTTPS on 443.
        proxyPort = 443;
        proxySSL = true;
        upnp = false;
        minifyStaticFiles = true;
      };

      web.sites.foundry = {
        inherit port;
        shared = true;
        healthPath = "/api/status";
        # The game runs over a WebSocket; maps, tokens and music are uploaded through the site.
        websockets = true;
        extraConfig = ''
          client_max_body_size 1G;
        '';
        homepage = {
          name = "Foundry VTT";
          group = "Apps";
          icon = "foundry-vtt.png";
          description = "Tabletop games";
        };
      };

      monitor.units = [ "foundryvtt" ];
    };
}
