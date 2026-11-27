# modules/features/rss.nix
{
  # Miniflux, an RSS reader, at rss.gatica.one over NetBird only. Sign-in is Pocket ID's (client "Miniflux", cosmos
  # group only) with local passwords off; the first sign-in creates the account. Phone apps and scripts (later
  # Hermes, for a digest) use Miniflux's API with a key made in its settings, which is why the site isn't behind
  # the oauth2-proxy gate.
  flake.modules.nixos.rss =
    { config, ... }:
    let
      port = 8086;
    in
    {
      sops.secrets.miniflux-oidc-secret = {
        sopsFile = ../../secrets/${config.networking.hostName}.yaml;
        restartUnits = [ "miniflux.service" ];
      };

      services.miniflux = {
        enable = true;
        # PostgreSQL on this host, made by the module.
        createDatabaseLocally = true;
        config = {
          LISTEN_ADDR = "127.0.0.1:${toString port}";
          BASE_URL = "https://rss.gatica.one";
          # No local admin: Pocket ID creates the one account.
          CREATE_ADMIN = 0;
          DISABLE_LOCAL_AUTH = 1;
          OAUTH2_PROVIDER = "oidc";
          OAUTH2_OIDC_DISCOVERY_ENDPOINT = "https://id.gatica.one";
          OAUTH2_OIDC_PROVIDER_NAME = "Pocket ID";
          OAUTH2_CLIENT_ID = "88998030-b02a-4905-979f-d181fdd1e690";
          # From the service's credentials (it runs as a dynamic user, which can't read the sops file itself).
          OAUTH2_CLIENT_SECRET_FILE = "%d/oidc-secret";
          OAUTH2_REDIRECT_URL = "https://rss.gatica.one/oauth2/oidc/callback";
          OAUTH2_USER_CREATION = 1;
        };
      };

      systemd.services.miniflux = {
        serviceConfig.LoadCredential = [ "oidc-secret:${config.sops.secrets.miniflux-oidc-secret.path}" ];
        # Pocket ID is on this host too; sign-in needs it answering.
        after = [ "pocket-id.service" ];
        wants = [ "pocket-id.service" ];
      };

      topology.self.services.miniflux = {
        name = "Miniflux";
        info = "rss.gatica.one";
        details.role.text = "RSS reader, with an API for phone apps and Hermes.";
      };

      web.sites.rss = {
        inherit port;
        healthPath = "/healthcheck";
        homepage = {
          name = "Miniflux";
          group = "Apps";
          icon = "miniflux.png";
          description = "News and blogs";
        };
      };

      monitor = {
        units = [ "miniflux" ];
        ports.miniflux = port;
      };
    };
}
