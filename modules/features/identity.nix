# modules/features/identity.nix
{
  # The homelab's sign-in: Pocket ID at id.gatica.one, passkeys only (no passwords to phish), as the OIDC provider for
  # the sites (Grafana itself, the rest through oauth2-proxy). A private site, so only the owner's devices reach it.
  # Its OIDC clients and groups are made through its API with the static API key (pocket-id-env), from lugh; the
  # owner's passkey is registered once at id.gatica.one/setup. Losing its database means registering passkeys again.
  flake.modules.nixos.identity =
    { config, ... }:
    let
      port = 1411;
    in
    {
      # ENCRYPTION_KEY (its signing keys at rest) and STATIC_API_KEY (admin API access, for setting up clients).
      sops.secrets.pocket-id-env.sopsFile = ../../secrets/${config.networking.hostName}.yaml;

      services.pocket-id = {
        enable = true;
        environmentFile = config.sops.secrets.pocket-id-env.path;
        settings = {
          APP_URL = "https://id.gatica.one";
          HOST = "127.0.0.1";
          PORT = port;
          TRUST_PROXY = true;
          ANALYTICS_DISABLED = true;
          VERSION_CHECK_DISABLED = true;
        };
      };

      # For the homelab map (modules/topology.nix).
      topology.self.services.pocket-id = {
        name = "Pocket ID";
        info = "id.gatica.one";
        details.role.text = "Passkey sign-in (OIDC) for the homelab's sites.";
      };

      web.sites.id = {
        inherit port;
        healthPath = "/healthz";
      };

      monitor = {
        units = [ "pocket-id" ];
        ports.pocket-id = port;
      };
    };
}
