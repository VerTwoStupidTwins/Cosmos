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
      authPort = 4180;
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

      # Sign-in for sites without their own (web.sites.<name>.sso): nginx asks oauth2-proxy about every request, and
      # oauth2-proxy sends the browser to Pocket ID when there's no session. One cookie for all of *.gatica.one, so one
      # sign-in covers every such site for a week. Its client only lets the cosmos group in.
      sops.secrets.oauth2-proxy-env.sopsFile = ../../secrets/${config.networking.hostName}.yaml;

      services.oauth2-proxy = {
        enable = true;
        provider = "oidc";
        oidcIssuerUrl = "https://id.gatica.one";
        clientID = "3122d664-0072-45ee-8f22-579c32435d53";
        # OAUTH2_PROXY_CLIENT_SECRET and OAUTH2_PROXY_COOKIE_SECRET.
        keyFile = config.sops.secrets.oauth2-proxy-env.path;
        redirectURL = "https://auth.gatica.one/oauth2/callback";
        scope = "openid email profile groups";
        httpAddress = "http://127.0.0.1:${toString authPort}";
        # nginx only asks; it never proxies the site itself through oauth2-proxy.
        upstream = [ "static://202" ];
        reverseProxy = true;
        trustedProxyIP = [ "127.0.0.1" ];
        setXauthrequest = true;
        email.domains = [ "*" ];
        cookie = {
          domain = ".gatica.one";
          expire = "168h";
          refresh = "1h";
        };
        extraConfig = {
          whitelist-domain = ".gatica.one";
          code-challenge-method = "S256";
          skip-provider-button = true;
        };
        nginx.domain = "auth.gatica.one";
      };

      web.sites.auth = {
        port = authPort;
        healthPath = "/ping";
      };

      monitor = {
        units = [
          "pocket-id"
          "oauth2-proxy"
        ];
        ports = {
          pocket-id = port;
          oauth2-proxy = authPort;
        };
      };
    };
}
