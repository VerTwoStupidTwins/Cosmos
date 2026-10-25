# Native storage and rootless Podman prerequisites for the Honcho container.
{ config, ... }:
{
  flake.modules.nixos."honcho-local" =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      honchoImage = pkgs.callPackage ../../../packages/honcho-image.nix { };
    in
    {
      # Keep the verified archive with the system; no activation-time pull.
      system.extraDependencies = [ honchoImage ];
      services.postgresql = {
        enable = true;
        package = pkgs.postgresql_17;
        extensions = ps: [ ps.pgvector ];
        enableTCPIP = false;
        # The pinned module assigns localhost even with enableTCPIP=false.
        # Override only this field to disable TCP entirely, including loopback.
        settings.listen_addresses = lib.mkForce "";
        authentication = "local honcho honcho peer";
        ensureDatabases = [ "honcho" ];
        ensureUsers = [
          {
            name = "honcho";
            ensureDBOwnership = true;
            ensureClauses = {
              login = true;
              superuser = false;
              createdb = false;
              createrole = false;
              replication = false;
            };
          }
        ];
      };
      # The pinned native module creates databases/roles in this setup unit,
      # not in postgresql.service; extensions must be enabled afterward.
      systemd.services.postgresql-setup.postStart = ''
        ${config.services.postgresql.finalPackage}/bin/psql \
          --set=ON_ERROR_STOP=1 --dbname=honcho \
          --file=${../../../packages/honcho-database.sql}
      '';
      users.groups.honcho = { };
      users.users.honcho = {
        isSystemUser = true;
        group = "honcho";
        home = "/var/lib/honcho";
        homeMode = "0700";
        createHome = true;
        autoSubUidGidRange = true;
        linger = true;
      };
      virtualisation.podman = {
        enable = true;
        dockerCompat = false;
      };
    };

  perSystem =
    { pkgs, ... }:
    let
      honchoImage = pkgs.callPackage ../../../packages/honcho-image.nix { };
    in
    {
      packages.honcho-image = honchoImage;
      packages.honcho-tokenizer-cache = pkgs.callPackage ../../../packages/honcho-tokenizer-cache.nix { };
      checks = {
        honcho-runtime = import ../../../tests/honcho-runtime.nix {
          inherit pkgs;
          odin = config.flake.nixosConfigurations.odin.config;
        };
        honcho-image = import ../../../tests/honcho-image.nix {
          inherit pkgs;
          image = honchoImage;
          odin = config.flake.nixosConfigurations.odin.config;
        };
        honcho-database = import ../../../tests/honcho-database.nix {
          inherit pkgs;
          odin = config.flake.nixosConfigurations.odin.config;
          thoth = config.flake.nixosConfigurations.thoth.config;
          argus = config.flake.nixosConfigurations.argus.config;
        };
      };
    };
}
