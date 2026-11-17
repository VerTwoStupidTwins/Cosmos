# modules/features/hermes-memory.nix
{
  # Hermes' own memory: durable memories and the wiki index in an embedded SurrealDB, served to a Hermes plugin over a
  # Unix socket by a Rust service.
  flake.modules.nixos.hermes =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      home = "/var/lib/hermes";
      socketDir = "/run/hermes-memory";
      state = "/var/lib/hermes-memory";
      postgres = config.services.postgresql.finalPackage;

      server = pkgs.rustPlatform.buildRustPackage {
        pname = "hermes-memory";
        version = "0.1.0";
        src = ./hermes-memory/server;
        cargoLock.lockFile = ./hermes-memory/server/Cargo.lock;
        # Nix builds link these system libraries instead of building their own copies. SurrealDB brings in aws-lc for
        # TLS, which a Unix socket never uses.
        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [
          pkgs.zstd
          pkgs.aws-lc
        ];
        # The tests build SurrealDB a second time, which doubles a long build; they run during development instead.
        doCheck = false;
      };

      common = [
        "--data ${state}/db"
        "--llama-swap-url http://127.0.0.1:${toString config.services.llama-swap.port}"
      ];

      memoryPlugin = pkgs.runCommand "hermes-memory" { } ''
        cp -r ${./hermes-memory/plugin} $out
      '';
    in
    {
      # Postgres goes when the way back is no longer needed.
      monitor.units = [
        "hermes-memory"
        "postgresql"
      ];
      monitor.memorySocket = "${socketDir}/api.sock";

      # Postgres held the memories until the Rust service. It stays, untouched, as the way back for a while.
      services.postgresql = {
        enable = true;
        # The data directory was created with 15, and a major upgrade needs a migration.
        package = pkgs.postgresql_15;
        extensions = extensions: [ extensions.pgvector ];
        ensureDatabases = [ "memory" ];
        # The service runs as hermes and signs in over the local socket as the same name.
        ensureUsers = [ { name = "hermes"; } ];
      };

      # Creating vector needs a superuser, and the service connects as an ordinary user.
      systemd.services.hermes-memory-database = {
        requires = [ "postgresql-setup.service" ];
        after = [ "postgresql-setup.service" ];
        path = [ postgres ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "postgres";
        };
        script = ''
          psql -d memory -c "CREATE EXTENSION IF NOT EXISTS vector"
          psql -d memory -c "ALTER DATABASE memory OWNER TO hermes"
          psql -d memory -c "ALTER SCHEMA public OWNER TO hermes"
        '';
      };

      # Moves the memories out of Postgres the first time the Rust service starts, then never runs again. A failure
      # leaves no database behind, so the next start tries again, and Postgres is only read.
      systemd.services.hermes-memory-migrate = {
        description = "Move Hermes' memories from Postgres to the Rust service";
        requires = [ "hermes-memory-database.service" ];
        after = [
          "hermes-memory-database.service"
          "llama-swap.service"
        ];
        unitConfig.ConditionPathExists = "!${state}/db";
        path = [ postgres ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "hermes";
          Group = "hermes";
          StateDirectory = "hermes-memory";
          StateDirectoryMode = "0700";
          UMask = "0077";
        };
        script = ''
          trap 'rm -rf ${state}/db ${state}/migration.json' ERR
          psql -d memory -X -A -t -v ON_ERROR_STOP=1 -f ${./hermes-memory/server/dump-postgres.sql} > ${state}/migration.json
          ${server}/bin/hermes-memory ${lib.concatStringsSep " " common} --import ${state}/migration.json
          ${server}/bin/hermes-memory ${lib.concatStringsSep " " common} --check
          rm ${state}/migration.json
        '';
      };

      systemd.services.hermes-memory = {
        description = "Hermes memory service";
        wantedBy = [ "multi-user.target" ];
        requires = [ "hermes-memory-migrate.service" ];
        after = [
          "hermes-memory-migrate.service"
          "llama-swap.service"
        ];

        serviceConfig = {
          User = "hermes";
          Group = "hermes";
          ExecStart = lib.concatStringsSep " " (
            [
              "${server}/bin/hermes-memory"
              "--socket ${socketDir}/api.sock"
              "--wiki ${home}/wiki"
              "--export-dir ${home}/wiki/memory"
              # Nightly at 3:30, keeping a week.
              "--backup-dir ${state}/backups"
            ]
            ++ common
          );
          # Lets SurrealDB flush and close before systemd gives up on it.
          TimeoutStopSec = 30;
          Restart = "on-failure";
          RestartSec = 10;
          RuntimeDirectory = "hermes-memory";
          RuntimeDirectoryMode = "0750";
          StateDirectory = "hermes-memory";
          StateDirectoryMode = "0700";

          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          # It reads the wiki and writes only the memory export inside it.
          ReadWritePaths = [ "${home}/wiki" ];
        };
      };

      services.hermes-agent = {
        extraPlugins = [ memoryPlugin ];
        environment.HERMES_MEMORY_SOCKET = "${socketDir}/api.sock";

        # This service replaced the wiki-search MCP server. Settings merge into Hermes' config file, so the old
        # entry would keep starting it with a stale index unless switched off here.
        settings.mcp_servers.wiki-search.enabled = false;
      };
    };
}
