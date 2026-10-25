# Native database prerequisites; only disposable, synthetic data enters this check.
{
  pkgs,
  odin,
  thoth,
  argus,
}:
let
  inherit (pkgs) lib;
  pg = odin.services.postgresql;
  checks = {
    databaseEnabledOnlyOnOdin =
      pg.enable && !thoth.services.postgresql.enable && !argus.services.postgresql.enable;
    privateSocketOnly = !pg.enableTCPIP && (pg.settings.listen_addresses or null) == "";
    dedicatedDatabase = builtins.elem "honcho" pg.ensureDatabases;
    dedicatedOwner = builtins.any (
      user:
      user.name == "honcho"
      && user.ensureDBOwnership
      && !(user.ensureClauses.superuser or true)
      && !(user.ensureClauses.createdb or true)
      && !(user.ensureClauses.createrole or true)
    ) pg.ensureUsers;
    peerAuthentication = lib.hasInfix "local honcho honcho peer" pg.authentication;
    postgres17 = pg.package.psqlSchema == "17";
    bootstrapAfterNativeSetup =
      lib.hasInfix "honcho-database.sql" (odin.systemd.services.postgresql-setup.postStart or "")
      && lib.hasInfix "--dbname=honcho" (odin.systemd.services.postgresql-setup.postStart or "");
    rootlessRuntimePrepared =
      odin.virtualisation.podman.enable
      && !odin.virtualisation.docker.enable
      && odin.users.users.honcho.isSystemUser
      && odin.users.users.honcho.autoSubUidGidRange;
  };
  failures = builtins.attrNames (lib.filterAttrs (_: passed: !passed) checks);
in
assert lib.assertMsg (
  failures == [ ]
) "Honcho database prerequisites failed: ${lib.concatStringsSep ", " failures}";
pkgs.runCommand "honcho-database-check"
  {
    nativeBuildInputs = [ pg.finalPackage ];
    LANG = "C";
  }
  ''
    set -euo pipefail
    export PGHOST="$TMPDIR/socket" PGUSER=postgres PGDATABASE=honcho
    mkdir -m 0700 "$PGHOST"
    # Trust applies only inside this disposable build sandbox, never production.
    initdb -D "$TMPDIR/data" --username=postgres --auth=trust --locale=C >/dev/null
    pg_ctl -D "$TMPDIR/data" -l "$TMPDIR/postgres.log" -o "-c listen_addresses= -k $PGHOST" -w start >/dev/null
    trap 'pg_ctl -D "$TMPDIR/data" -m fast -w stop >/dev/null' EXIT
    psql --dbname=postgres --set=ON_ERROR_STOP=1 <<'SQL'
    CREATE ROLE honcho LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
    CREATE DATABASE honcho OWNER honcho;
    SQL
    psql --set=ON_ERROR_STOP=1 --file=${../packages/honcho-database.sql} >/dev/null
    psql --set=ON_ERROR_STOP=1 --file=${../packages/honcho-database.sql} >/dev/null
    test "$(psql -Atc "SELECT count(*) FROM pg_extension WHERE extname IN ('vector', 'pg_trgm', 'btree_gin')")" = 3
    test "$(psql -Atc "SHOW listen_addresses")" = ""
    PGUSER=honcho psql --set=ON_ERROR_STOP=1 <<'SQL'
    CREATE SCHEMA honcho;
    CREATE EXTENSION IF NOT EXISTS vector;
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
    CREATE EXTENSION IF NOT EXISTS btree_gin;
    CREATE TABLE honcho.memories (id int PRIMARY KEY, fact text, embedding vector(3));
    INSERT INTO honcho.memories VALUES (1, 'public-fixture-prefers-tea', '[1,0,0]'), (2, 'public-fixture-prefers-coffee', '[0,1,0]');
    CREATE INDEX ON honcho.memories USING gin (fact gin_trgm_ops);
    CREATE INDEX ON honcho.memories USING gin (id);
    SQL
    test "$(PGUSER=honcho psql -Atc "SELECT fact FROM honcho.memories ORDER BY embedding <-> '[1,0,0]' LIMIT 1")" = public-fixture-prefers-tea
    if PGUSER=honcho psql --set=ON_ERROR_STOP=1 -c 'CREATE ROLE forbidden_superuser SUPERUSER' >/dev/null 2>&1; then
      echo 'Honcho must not create roles or grant superuser' >&2
      exit 1
    fi
    if PGUSER=honcho psql --set=ON_ERROR_STOP=1 -c 'CREATE DATABASE forbidden_database' >/dev/null 2>&1; then
      echo 'Honcho must not create other databases' >&2
      exit 1
    fi
    # Now exercise real peer authentication: the builder's OS identity must
    # not be able to impersonate the Honcho database role.
    printf 'fixture_admin %s postgres\n' "$(id -un)" > "$TMPDIR/data/pg_ident.conf"
    printf '%s\n' 'local all postgres peer map=fixture_admin' 'local all all peer' > "$TMPDIR/data/pg_hba.conf"
    pg_ctl -D "$TMPDIR/data" -m fast -w stop >/dev/null
    pg_ctl -D "$TMPDIR/data" -l "$TMPDIR/postgres.log" -o "-c listen_addresses= -k $PGHOST" -w start >/dev/null
    test "$(psql -Atc 'SELECT count(*) FROM honcho.memories')" = 2
    if PGUSER=honcho psql --set=ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null 2>&1; then
      echo 'An unrelated OS identity must not impersonate Honcho via peer auth' >&2
      exit 1
    fi
    mkdir "$out"
    printf '%s\n' 'vector pg_trgm btree_gin: synthetic search, restricted role, peer authentication and restart persistence passed' > "$out/result"
  ''
