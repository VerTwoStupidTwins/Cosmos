# modules/features/matrix.nix
{
  # A Matrix homeserver for the homelab: Tuwunel at matrix.gatica.one, behind the web gateway (web.nix), so reachable
  # only over NetBird. It doesn't federate, and accounts are made with the registration token in
  # matrix-registration-token; the first account made becomes the admin.
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
          # Apps still try other servers now and then (the public room directory, joining by an outside address), and
          # each refused request was logged as an ERROR. With federation off that's expected, so it isn't logged.
          log = "info,tuwunel_service::federation::execute=off";
          # RocksDB's direct I/O writes fail on lugh's bcachefs ("pwrite … Invalid argument"), which stopped Tuwunel
          # from starting once its database had anything to write out. Ordinary buffered writes work.
          rocksdb_direct_io = false;
          allow_registration = true;
          registration_token_file = config.sops.secrets.matrix-registration-token.path;
          # Apps that only know the server name look here for the address.
          well_known.client = "https://${domain}";
        };
      };

      sops.secrets.matrix-registration-token = {
        sopsFile = ../../secrets/${config.networking.hostName}.yaml;
        owner = config.services.matrix-tuwunel.user;
      };

      web.sites.matrix = {
        inherit port;
        healthPath = "/_matrix/client/versions";
        # Uploads up to Tuwunel's own limit.
        extraConfig = "client_max_body_size ${toString config.services.matrix-tuwunel.settings.global.max_request_size};";
      };

      monitor = {
        units = [ "tuwunel" ];
        ports.tuwunel = port;
      };
    };
}
