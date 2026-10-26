# Official rootless Honcho application; native storage is in honcho-local.nix.
_: {
  flake.modules.nixos."honcho-local" =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      image = pkgs.callPackage ../../../packages/honcho-image.nix { };
      tokenizers = pkgs.callPackage ../../../packages/honcho-tokenizer-cache.nix { };
      model = {
        transport = "openai";
        model = "gemma4-balanced-q4";
        fallback = null;
        max_output_tokens = 8192;
        structured_output_mode = "json_schema";
        overrides = {
          base_url = "http://127.0.0.1:18094/v1";
          provider_params.extra_body.chat_template_kwargs.enable_thinking = false;
        };
      };
      environment = {
        AUTH_USE_AUTH = "true";
        # The local OpenAI-compatible SDK requires a nonempty placeholder,
        # not a cloud credential. No cloud key is provisioned to these services.
        LLM_OPENAI_API_KEY = "local-sdk-placeholder-not-a-credential";
        LLM_OPENAI_BASE_URL = "http://127.0.0.1:18094/v1";
        HONCHO_DB_USER = "honcho";
        HONCHO_DB_NAME = "honcho";
        HONCHO_DB_SOCKET = "/run/postgresql";
        HONCHO_API_PORT = "8000";
        TIKTOKEN_CACHE_DIR = "/opt/tiktoken";
        EMBEDDING_VECTOR_DIMENSIONS = "768";
        EMBEDDING_MODEL_CONFIG = builtins.toJSON {
          transport = "openai";
          model = "embeddinggemma2";
          dimensions_mode = "never";
          encoding_format_mode = "float";
          max_batch_size = 8;
          timeout = 60;
          overrides.base_url = "http://127.0.0.1:18093/v1";
        };
        DERIVER_MODEL_CONFIG = builtins.toJSON model;
        SUMMARY_MODEL_CONFIG = builtins.toJSON model;
        DREAM_DEDUCTION_MODEL_CONFIG = builtins.toJSON model;
        DREAM_INDUCTION_MODEL_CONFIG = builtins.toJSON model;
        DIALECTIC_LEVELS = builtins.toJSON (
          lib.genAttrs [ "minimal" "low" "medium" "high" "max" ] (_: {
            model_config = model;
          })
        );
        DERIVER_WORKERS = "1";
        DERIVER_FLUSH_ENABLED = "true";
        CACHE_ENABLED = "false";
        DREAM_ENABLED = "false";
        TELEMETRY_ENABLED = "false";
        TELEMETRY_TRACE_PAYLOADS_ENABLED = "false";
        SENTRY_ENABLED = "false";
        METRICS_ENABLED = "false";
        DB_POOL_SIZE = "3";
        DB_MAX_OVERFLOW = "2";
        DB_SQL_DEBUG = "false";
        LOG_LEVEL = "WARNING";
        NO_PROXY = "127.0.0.1,localhost";
      };
      common = name: {
        image = "${image.imageName}:${image.imageTag}";
        imageFile = image;
        pull = "never";
        podman.user = "honcho";
        # Keep image app UID 100/GID 101 mapped to the native honcho identity.
        user = "100:101";
        networks = [ "host" ];
        entrypoint = "/app/.venv/bin/python";
        cmd = [
          "/opt/cosmos-entrypoint.py"
          name
        ];
        inherit environment;

        volumes = [
          "/run/postgresql:/run/postgresql:ro"
          "${tokenizers}:/opt/tiktoken:ro"
          "${../../../packages/honcho-entrypoint.py}:/opt/cosmos-entrypoint.py:ro"
        ];
        # Keep possible error payloads out of the shared system journal.
        # Podman's file log is inside honcho's private 0700 storage home.
        log-driver = "k8s-file";
        extraOptions = [
          # Inherit the manager-loaded value, never a secret in Nix/argv or a
          # per-unit credential mount hidden by Podman's shared rootless namespace.
          "--env=AUTH_JWT_SECRET"
          "--userns=keep-id:uid=100,gid=101"
          "--read-only"
          "--security-opt=no-new-privileges"
          "--cap-drop=ALL"
          "--pids-limit=256"
          "--memory=4g"
          "--http-proxy=false"
          "--tmpfs=/tmp:rw,nosuid,nodev,mode=1777"
          "--log-opt=max-size=10mb"
        ];
      };
      egress = pkgs.writeText "cosmos-honcho-egress.nft" ''
        destroy table inet cosmos_honcho
        table inet cosmos_honcho {
          chain output {
            type filter hook output priority -5; policy accept;
            meta skuid "honcho" ip daddr 127.0.0.1 ct direction reply ct state established,related accept
            meta skuid "honcho" ip daddr 127.0.0.1 tcp dport { 8000, 18093, 18094 } accept
            meta skuid "honcho" counter reject
          }
        }
      '';
      containerService = {
        after = [
          "postgresql-setup.service"
          "honcho-credentials.service"
          "cosmos-honcho-egress.service"
          "cosmos-honcho-inference.service"
        ];
        requires = [
          "postgresql-setup.service"
          "honcho-credentials.service"
          "cosmos-honcho-egress.service"
          "cosmos-honcho-inference.service"
        ];
        environment.XDG_RUNTIME_DIR = "/run/user/${toString config.users.users.honcho.uid}";
        serviceConfig = {
          EnvironmentFile = [ "/var/lib/cosmos-honcho/server.env" ];
          ProtectSystem = "full";
          # ProtectHome=yes also hides /run/user, which rootless Podman needs.
          ProtectHome = false;
          InaccessiblePaths = [
            "/home"
            "/root"
            "-/run/secrets"
            "-/var/lib/hermes"
            "/var/lib/cosmos-honcho"
          ];
          UMask = "0077";
          # Native OCI units default to unlimited startup; bound readiness here.
          TimeoutStartSec = lib.mkForce 300;
        };
      };
    in
    {
      # Retain the same archive used by both containers; never pull on activation.
      system.extraDependencies = [ image ];
      virtualisation.oci-containers = {
        backend = "podman";
        containers = {
          honcho-api = common "api";
          honcho-worker = (common "worker") // {
            dependsOn = [ "honcho-api" ];
          };
        };
      };
      systemd.services = {
        honcho-credentials = {
          description = "Provision private local Honcho signing and workspace credentials";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "root";
            StateDirectory = "cosmos-honcho";
            StateDirectoryMode = "0700";
            UMask = "0077";
            ExecStart = "${pkgs.python3}/bin/python3 ${../../../packages/honcho-credentials.py} --state-dir /var/lib/cosmos-honcho";
            NoNewPrivileges = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            CapabilityBoundingSet = [ ];
            RestrictAddressFamilies = [ "AF_UNIX" ];
          };
        };
        cosmos-honcho-egress = {
          description = "Enforce local-only networking for the Honcho UID";
          after = [ "users-groups.service" ];
          before = [
            "podman-honcho-api.service"
            "podman-honcho-worker.service"
          ];
          serviceConfig = import ../../../packages/agent-egress-service.nix {
            inherit pkgs;
            rules = egress;
          };
        };
        cosmos-honcho-inference = {
          description = "Fixed local Gemma and text-only EmbeddingGemma interfaces for Honcho";
          after = [ "llama-swap.service" ];
          wants = [ "llama-swap.service" ];
          serviceConfig = {
            DynamicUser = true;
            ExecStart = "${pkgs.python3}/bin/python3 ${../../../packages/honcho-inference-gateway.py} --core ${../../../packages/hermes-inference-gateway.py}";
            Restart = "on-failure";
            NoNewPrivileges = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_UNIX"
            ];
            IPAddressDeny = "any";
            IPAddressAllow = "localhost";
            MemoryMax = "256M";
          };
        };
        podman-honcho-api = lib.recursiveUpdate containerService {
          # After= also waits for ExecStartPost. Avoid Podman's broken self-exe
          # health-timer path without allowing the worker to race migrations.
          serviceConfig.ExecStartPost = [
            "${pkgs.python3}/bin/python3 ${../../../packages/honcho-ready.py}"
          ];
        };
        podman-honcho-worker = containerService;
      };
    };
}
