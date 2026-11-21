# modules/features/web.nix
{
  # The host's web services under <name>.gatica.one, through nginx with one wildcard certificate, reachable only over
  # NetBird. Public DNS points each name at the host's NetBird address, which only NetBird peers can reach, and the
  # certificate comes through Spaceship's DNS API, so nothing has to be reachable from the internet.
  flake.modules.nixos.web =
    { config, lib, ... }:
    let
      domain = "gatica.one";
      cfg = config.web;
    in
    {
      options.web.sites = lib.mkOption {
        description = "Services served at <name>.${domain}, proxied to a port on this host.";
        default = { };
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              port = lib.mkOption {
                type = lib.types.port;
                description = "The local port the service listens on, on 127.0.0.1.";
              };
              websockets = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Pass WebSocket upgrades through.";
              };
              extraConfig = lib.mkOption {
                type = lib.types.lines;
                default = "";
                description = "Extra nginx directives for the site's location.";
              };
            };
          }
        );
      };

      config = {
        sops.secrets.spaceship-api.sopsFile = ../../secrets/${config.networking.hostName}.yaml;

        security.acme = {
          acceptTerms = true;
          certs.${domain} = {
            domain = "*.${domain}";
            dnsProvider = "spaceship";
            environmentFile = config.sops.secrets.spaceship-api.path;
            # lego looks names up through the system resolver otherwise, and systemd-resolved can answer NXDOMAIN,
            # cached from before the record existed.
            dnsResolver = "1.1.1.1:53";
            # lego's own propagation check passes within seconds, before Let's Encrypt's resolvers see Spaceship's
            # record (they answered NXDOMAIN on the first order), so it waits out the record's 120-second TTL instead.
            extraLegoRunFlags = [
              "--dns.propagation.wait"
              "120s"
            ];
            extraLegoRenewFlags = [
              "--dns.propagation.wait"
              "120s"
            ];
            group = config.services.nginx.group;
          };
        };

        services.nginx = {
          enable = true;
          recommendedProxySettings = true;
          recommendedTlsSettings = true;
          recommendedOptimisation = true;
          recommendedGzipSettings = true;
          virtualHosts = lib.mapAttrs' (
            name: site:
            lib.nameValuePair "${name}.${domain}" {
              useACMEHost = domain;
              forceSSL = true;
              locations."/" = {
                proxyPass = "http://127.0.0.1:${toString site.port}";
                proxyWebsockets = site.websockets;
                inherit (site) extraConfig;
              };
            }
          ) cfg.sites;
        };

        networking.firewall.interfaces."nb-wt0".allowedTCPPorts = [
          80
          443
        ];

        monitor = {
          units = [ "nginx" ];
          ports.nginx = 443;
        };
      };
    };
}
