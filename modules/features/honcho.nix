# modules/features/honcho.nix
{
  flake.modules.nixos.honcho =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      llamaSwap = "http://127.0.0.1:8080/v1";
      apiPort = 8000;

      honchoSource = pkgs.fetchFromGitHub {
        owner = "plastic-labs";
        repo = "honcho";
        tag = "v3.5.0";
        hash = "sha256-iGxhRFDZzrojQ1/24Q+QNh8bAnfAXTe94IqPoqCjipQ=";
      };

      honchoImage = "ghcr.io/plastic-labs/honcho:v3.5.0@sha256:23ff96bf62ab2ca14928e6766db1a30a7729f5b7c9e2285af0cd4a179c0d393d";

      dashboardPort = 8090;
      dashboardPasswordFile = "/etc/nginx/openconcho.htpasswd";

      dashboardSource = pkgs.fetchFromGitHub {
        owner = "offendingcommit";
        repo = "openconcho";
        tag = "v0.17.1";
        hash = "sha256-E9KSo5kq1XFa0ArkswuW+kSoAaOEfJ43/Uf7gtlQNgw=";
      };

      # Its default port is taken by llama-swap, and it has no login of its own.
      dashboardNginxTemplate = pkgs.runCommand "openconcho-nginx.conf.template" { } ''
        sed \
          -e 's/listen       8080;/listen       ${toString dashboardPort};/' \
          -e 's/listen       \[::\]:8080;/listen       [::]:${toString dashboardPort};/' \
          -e 's|server_tokens off;|server_tokens off;\n    auth_basic "OpenConcho";\n    auth_basic_user_file ${dashboardPasswordFile};|' \
          ${dashboardSource}/docker/nginx.conf.template > $out
      '';

      hermesPlugin = pkgs.runCommand "honcho" { } ''
        cp -r ${honchoSource}/hermes-plugin-honcho $out
      '';

      pythonPackages = config.services.hermes-agent.package.python.pkgs;

      # Its dependencies come from the Hermes environment, which refuses packages that shadow its own.
      honchoClient = pythonPackages.buildPythonPackage {
        pname = "honcho-ai";
        version = "2.8.0";
        format = "wheel";
        src = pkgs.fetchurl {
          url = "https://files.pythonhosted.org/packages/py3/h/honcho_ai/honcho_ai-2.8.0-py3-none-any.whl";
          hash = "sha256-dL+IWz2GwRG2pXTmldULhhoIDiDxC+7P5gM27s/ZI34=";
        };
        dontCheckRuntimeDeps = true;
      };

      useModel = model: prefix: {
        "${prefix}__TRANSPORT" = "openai";
        "${prefix}__MODEL" = model;
        "${prefix}__OVERRIDES__BASE_URL" = llamaSwap;
      };

      honchoEnvironment = {
        DB_CONNECTION_URI = "postgresql+psycopg://honcho@127.0.0.1:5432/honcho";
        CACHE_URL = "redis://127.0.0.1:6379/0?suppress=true";
        CACHE_ENABLED = "true";
        AUTH_USE_AUTH = "false";

        # llama-swap ignores this, but Honcho refuses to start without a key.
        LLM_OPENAI_API_KEY = "local";

        # Must match the model before the database is first created.
        EMBEDDING_VECTOR_DIMENSIONS = "768";
        EMBEDDING_MODEL_CONFIG__TRANSPORT = "openai";
        EMBEDDING_MODEL_CONFIG__MODEL = "embedding";
        EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL = llamaSwap;
        EMBEDDING_MODEL_CONFIG__MAX_BATCH_SIZE = "10";

        # A thinking model would otherwise spend the summary's whole token limit on reasoning.
        SUMMARY_MODEL_CONFIG__THINKING_EFFORT = "none";
      }
      # Each feature needs its own endpoint, or it falls back to OpenAI.
      # Memory upkeep runs in the background, while chat answers have someone waiting.
      // lib.mergeAttrsList (
        map (useModel "worker") [
          "DERIVER_MODEL_CONFIG"
          "SUMMARY_MODEL_CONFIG"
          "DREAM_DEDUCTION_MODEL_CONFIG"
          "DREAM_INDUCTION_MODEL_CONFIG"
        ]
        ++ map (level: useModel "helper" "DIALECTIC_LEVELS__${level}__MODEL_CONFIG") [
          "minimal"
          "low"
          "medium"
          "high"
          "max"
        ]
      );

      # Host networking lets Honcho reach llama-swap, which only listens on localhost.
      hostNetwork = [ "--network=host" ];
    in
    {
      services.postgresql = {
        enable = true;
        # The major version Honcho's own compose file runs.
        package = pkgs.postgresql_15;
        extensions = extensions: [ extensions.pgvector ];
        ensureDatabases = [ "honcho" ];
        ensureUsers = [
          {
            name = "honcho";
            ensureDBOwnership = true;
          }
        ];
        authentication = "host honcho honcho 127.0.0.1/32 trust";
      };

      # Creating vector needs a superuser, and Honcho connects as an ordinary user.
      systemd.services.honcho-database = {
        requires = [ "postgresql-setup.service" ];
        after = [ "postgresql-setup.service" ];
        path = [ config.services.postgresql.finalPackage ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "postgres";
        };
        script = ''
          for extension in vector pg_trgm btree_gin; do
            psql -d honcho -c "CREATE EXTENSION IF NOT EXISTS $extension"
          done
        '';
      };

      services.redis.servers.honcho = {
        enable = true;
        bind = "127.0.0.1";
        port = 6379;
      };

      systemd.services.podman-honcho-api = {
        requires = [
          "honcho-database.service"
          "redis-honcho.service"
        ];
        after = [
          "honcho-database.service"
          "redis-honcho.service"
        ];
      };

      virtualisation.podman.enable = true;

      virtualisation.oci-containers = {
        backend = "podman";

        containers = {
          honcho-api = {
            image = honchoImage;
            entrypoint = "sh";
            # The image's entrypoint binds every interface.
            cmd = [
              "-c"
              "/app/.venv/bin/python scripts/provision_db.py && /app/.venv/bin/python scripts/configure_embeddings.py --yes && exec /app/.venv/bin/fastapi run --host 127.0.0.1 --port ${toString apiPort} src/main.py"
            ];
            environment = honchoEnvironment;
            extraOptions = hostNetwork;
          };

          honcho-deriver = {
            image = honchoImage;
            entrypoint = "/app/.venv/bin/python";
            cmd = [
              "-m"
              "src.deriver"
            ];
            environment = honchoEnvironment;
            dependsOn = [ "honcho-api" ];
            extraOptions = hostNetwork;
          };

          openconcho = {
            image = "ghcr.io/offendingcommit/openconcho-web:0.17.1@sha256:62dc58ba22e533bb795021c80cfcc101c3a260c670accdb8e27bdc46a176fd2c";
            environment = {
              OPENCONCHO_DEFAULT_HONCHO_URL = "http://127.0.0.1:${toString apiPort}";
              # Its proxy otherwise forwards to any address a client names.
              OPENCONCHO_UPSTREAM_ALLOWLIST = "127.0.0.1";
            };
            volumes = [
              "${dashboardNginxTemplate}:/etc/nginx/templates/default.conf.template:ro"
              "${config.sops.secrets.openconcho-htpasswd.path}:${dashboardPasswordFile}:ro"
            ];
            dependsOn = [ "honcho-api" ];
            extraOptions = hostNetwork;
          };
        };
      };

      # nginx runs as an unprivileged user in the container, and this holds only a password hash.
      sops.secrets.openconcho-htpasswd = {
        mode = "0444";
        restartUnits = [ "podman-openconcho.service" ];
      };

      networking.firewall.interfaces."nb-wt0".allowedTCPPorts = [ dashboardPort ];

      services.hermes-agent = {
        extraPlugins = [ hermesPlugin ];
        extraPythonPackages = [ honchoClient ];

        # Hermes names providers after their directory, and Nix-managed plugins get this prefix.
        settings.memory.provider = "nix-managed-honcho";

        hermesHomeFiles."honcho.json" = builtins.toJSON {
          enabled = true;
          baseUrl = "http://127.0.0.1:${toString apiPort}";
          workspace = "hermes";
          peerName = "twins";
          aiPeer = "hermes";
          # Injecting memories into the prompt would invalidate the main model's prompt cache.
          recallMode = "tools";
          # Tools mode otherwise opens the session at the first Honcho tool call and drops every turn before it.
          initOnSessionStart = true;
          # Desktop and gateway users have runtime IDs, and all of them are the same person here.
          pinUserPeer = true;
        };
      };
    };
}
