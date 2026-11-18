# modules/features/matrix.nix
{
  # A Matrix homeserver for the homelab: Tuwunel behind nginx, reachable only over NetBird. It doesn't federate, and
  # accounts are made with a registration token. Hermes talks to it as @hermes:matrix.gatica.one.
  flake.modules.nixos.matrix =
    { config, pkgs, ... }:
    let
      # Also the server name, so IDs look like @twins:matrix.gatica.one and apps find the server from the ID alone.
      # It can't change once the server has users.
      domain = "matrix.gatica.one";
      port = 6167;
    in
    {
      services.matrix-tuwunel = {
        enable = true;
        # nixpkgs' Rust setup now steers crates to system libraries, pointing them at paths that don't exist
        # where there is none (JEMALLOC_OVERRIDE, AWS_LC_SYS_USE_SYSTEM…), and Tuwunel's jemalloc and AWS-LC
        # crates stop there (Hydra fails the same way). Without that step they build their own, as Tuwunel's
        # own build does.
        package = pkgs.matrix-tuwunel.overrideAttrs { dontCargoUseSystemLibs = true; };
        settings.global = {
          server_name = domain;
          address = [ "127.0.0.1" ];
          port = [ port ];
          allow_federation = false;
          trusted_servers = [ ];
          # Only with a token; the first account made becomes the admin.
          allow_registration = true;
          registration_token_file = config.sops.secrets.matrix-registration-token.path;
          # Apps that only know the server name look here for the address.
          well_known.client = "https://${domain}";
        };
      };

      # No copy-on-write for the database: on btrfs, RocksDB's preallocated write-ahead logs can't reserve
      # space and pin old extents. The attribute only reaches files made after it's set, which is why it's
      # set on the directory before Tuwunel first fills it. DynamicUser keeps the real directory under
      # /var/lib/private.
      systemd.tmpfiles.rules = [
        "d /var/lib/private/tuwunel 0700 - - -"
        "h /var/lib/private/tuwunel - - - - +C"
      ];

      sops.secrets.matrix-registration-token = {
        sopsFile = ../../secrets/kobold.yaml;
        owner = config.services.matrix-tuwunel.user;
      };

      # The certificate comes through Spaceship's DNS API, so nothing has to be reachable from the internet. Public DNS
      # points matrix.gatica.one at kobold's NetBird address, which only NetBird peers can reach.
      sops.secrets.spaceship-api = {
        sopsFile = ../../secrets/kobold.yaml;
      };
      security.acme = {
        acceptTerms = true;
        certs.${domain} = {
          dnsProvider = "spaceship";
          environmentFile = config.sops.secrets.spaceship-api.path;
          # lego checks the challenge record through the system resolver otherwise, and systemd-resolved
          # answered NXDOMAIN (cached from before the record existed) until lego gave up.
          dnsResolver = "1.1.1.1:53";
          group = config.services.nginx.group;
        };
      };

      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;
        virtualHosts.${domain} = {
          useACMEHost = domain;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString port}";
            extraConfig = "client_max_body_size ${toString config.services.matrix-tuwunel.settings.global.max_request_size};";
          };
        };
      };

      networking.firewall.interfaces."nb-wt0".allowedTCPPorts = [
        80
        443
      ];

      monitor = {
        units = [
          "tuwunel"
          "nginx"
        ];
        ports = {
          tuwunel = port;
          nginx = 443;
        };
      };
    };
}
