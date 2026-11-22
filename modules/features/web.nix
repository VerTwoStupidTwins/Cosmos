# modules/features/web.nix
{ config, ... }:
let
  # The addresses private sites answer (modules/netbird-policies.nix): the owner's devices and lugh.
  privateClients = config.cosmos.netbird.privateSiteClients;
  peers = config.cosmos.netbird.peers;
in
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
          lib.types.submodule (
            { config, ... }:
            {
              # Shared sites (by default those fronting the shared NAS) answer anyone NetBird lets reach lugh, the brother's
              # devices included; private ones only the owner's devices and lugh itself, and 403 to the rest.
              config.shared = lib.mkDefault (config.upstream != null);
              options = {
                shared = lib.mkOption {
                  type = lib.types.bool;
                  description = "Whether others on the NetBird account (the brother's devices) may use it; by default only NAS-fronted sites.";
                };
                peers = lib.mkOption {
                  type = lib.types.listOf (lib.types.enum (builtins.attrNames peers));
                  default = [ ];
                  example = [ "nabu" ];
                  description = "Other NetBird peers (modules/netbird-policies.nix) a private site also answers, such as a server that pulls from it.";
                };
                port = lib.mkOption {
                  type = lib.types.nullOr lib.types.port;
                  default = null;
                  description = "The local port the service listens on, on 127.0.0.1. Either this or upstream.";
                };
                upstream = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = "https://100.94.10.20:5001";
                  description = ''
                    A service on another machine, by its NetBird address (scheme, address, port), for things lugh only
                    fronts, like the shared NAS. Its own certificate isn't checked: the hop runs inside NetBird's
                    encrypted tunnel. Either this or port.
                  '';
                };
                healthPath = lib.mkOption {
                  type = lib.types.str;
                  default = "/";
                  description = "A path that answers 2xx while the service is healthy, for the blackbox probe.";
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
          )
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
              extraConfig = lib.optionalString (!site.shared) (
                lib.concatMapStrings (ip: "allow ${ip};\n") (
                  [
                    "127.0.0.1"
                    "::1"
                  ]
                  ++ privateClients
                  ++ map (peer: peers.${peer}.ip) site.peers
                )
                + "deny all;\n"
              );
              locations."/" = {
                proxyPass =
                  if site.upstream != null then site.upstream else "http://127.0.0.1:${toString site.port}";
                proxyWebsockets = site.websockets;
                inherit (site) extraConfig;
              };
            }
          ) cfg.sites;
        };

        assertions = lib.mapAttrsToList (name: site: {
          assertion = (site.port == null) != (site.upstream == null);
          message = "web.sites.${name}: set exactly one of port or upstream.";
        }) cfg.sites;

        networking.firewall.interfaces."nb-wt0".allowedTCPPorts = [
          80
          443
        ];

        # The host finds its own sites without DNS (services here sign in at id.gatica.one), at the NetBird address the
        # private sites let in.
        networking.hosts.${peers.${config.networking.hostName}.ip} = map (name: "${name}.${domain}") (
          builtins.attrNames cfg.sites
        );

        monitor = {
          units = [ "nginx" ];
          ports.nginx = 443;
        };
      };
    };
}
