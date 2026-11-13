# modules/features/hermes-memory.nix
{
  # Hermes' own memory: durable memories and the wiki index in Postgres, served to a Hermes plugin over a Unix socket.
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
      backups = "/var/lib/hermes-memory/backups";
      postgres = config.services.postgresql.finalPackage;

      python = pkgs.python3.withPackages (p: [
        p.psycopg
        p.pyyaml
      ]);

      memoryPlugin = pkgs.runCommand "hermes-memory" { } ''
        cp -r ${./hermes-memory/plugin} $out
      '';
    in
    {
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

      systemd.services.hermes-memory = {
        description = "Hermes memory service";
        wantedBy = [ "multi-user.target" ];
        requires = [ "hermes-memory-database.service" ];
        after = [
          "hermes-memory-database.service"
          "llama-swap.service"
        ];

        serviceConfig = {
          User = "hermes";
          Group = "hermes";
          ExecStart = lib.concatStringsSep " " [
            "${python}/bin/python3 -I ${./hermes-memory/service.py}"
            "--socket ${socketDir}/api.sock"
            "--database 'dbname=memory host=/run/postgresql'"
            "--llama-swap-url http://127.0.0.1:${toString config.services.llama-swap.port}"
            "--wiki ${home}/wiki"
            "--export-dir ${home}/wiki/memory"
          ];
          Restart = "on-failure";
          RestartSec = 10;
          RuntimeDirectory = "hermes-memory";
          RuntimeDirectoryMode = "0750";

          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          # It reads the wiki and writes only the memory export inside it.
          ReadWritePaths = [ "${home}/wiki" ];
        };
      };

      # A nightly copy of the memories, until they can go to the NAS.
      systemd.services.hermes-memory-backup = {
        description = "Back up Hermes' memory database";
        requires = [ "hermes-memory-database.service" ];
        after = [ "hermes-memory-database.service" ];
        path = [
          postgres
          pkgs.findutils
        ];
        serviceConfig = {
          Type = "oneshot";
          User = "hermes";
          Group = "hermes";
          StateDirectory = "hermes-memory/backups";
          StateDirectoryMode = "0700";
          UMask = "0077";
        };
        script = ''
          pg_dump --format=custom --dbname=memory --file=${backups}/memory-$(date +%F).dump
          find ${backups} -name 'memory-*.dump' -mtime +14 -delete
        '';
      };

      systemd.timers.hermes-memory-backup = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "04:00";
          Persistent = true;
        };
      };

      services.hermes-agent = {
        extraPlugins = [ memoryPlugin ];
        environment.HERMES_MEMORY_SOCKET = "${socketDir}/api.sock";
      };
    };
}
