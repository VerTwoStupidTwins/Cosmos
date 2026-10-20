# Odin's on-demand Vulkan model roster; the standalone GPU instances stay off.
{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  flake.modules.nixos.odin =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      backend = config.services.llama-cpp-instances.amd;
      server = lib.getExe' backend.package "llama-server";
      modelRoot = "/var/lib/llama-models";
      qwenModel = "${modelRoot}/qwen36-reap-opus-mtp-f11f37b9ad21/Qwen3.6-29B-REAP-Opus-Reasoning-Distill-MTP-Q6_K.gguf";
      swiftModel = "${modelRoot}/swift15-qwen38-27b-gsq-rco-d74895bbe5db/Swift-1.5-Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf";
      artifacts = [
        {
          source = "/home/twins/.local/share/cosmos-models/barozp-qwen36-reap-opus-mtp/f11f37b9ad21038478066fc1e532dfb92165fccf/Qwen3.6-29B-REAP-Opus-Reasoning-Distill-MTP-Q6_K.gguf";
          destination = qwenModel;
          # Matches the publisher's SHA-256 at the pinned Hub revision.
          contentHash = "27b6c065ff4ba02d76dc11116ecebb78b4bc38aaa27637414c8008ba000db4ae";
          warning = "";
        }
        {
          source = "/home/twins/.local/share/cosmos-models/swift15-qwen38-27b-gsq-rco/d74895bbe5db4bec1e0024e7cc87d59c02d7631a/Swift-1.5-Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf";
          destination = swiftModel;
          contentHash = "9aecf1cd41b2cb2f32a74e0d889e33855ebef43b26f43b43feb5720239e677e5";
          warning = "";
        }
      ];
      provisionModels = pkgs.writeShellApplication {
        name = "odin-provision-inference-models";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          umask 022
          staging=""
          trap 'if [[ -n "$staging" ]]; then rm -f -- "$staging"; fi' EXIT
          verify() {
            printf '%s  %s\n' "$1" "$2" | sha256sum --check --status
          }
          provision() {
            local source="$1" destination="$2" expected="$3"
            if [[ -e "$destination" ]]; then
              if ! verify "$expected" "$destination"; then
                printf 'Existing model has unexpected bytes; refusing overwrite: %s\n' "$destination" >&2
                return 1
              fi
              return
            fi
            if [[ ! -f "$source" ]] || ! verify "$expected" "$source"; then
              printf 'Missing or changed source model; downloads remain a separate operation: %s\n' "$source" >&2
              return 1
            fi
            install -d -m 0755 -- "$(dirname "$destination")"
            staging=$(mktemp "$(dirname "$destination")/.model.XXXXXX")
            cp --reflink=auto -- "$source" "$staging"
            verify "$expected" "$staging"
            chmod 0444 -- "$staging"
            mv --no-clobber -- "$staging" "$destination"
            if [[ -e "$staging" ]]; then
              printf 'Destination appeared during provisioning; refusing replacement: %s\n' "$destination" >&2
              return 1
            fi
            staging=""
            verify "$expected" "$destination"
            printf 'Provisioned approved model bytes: %s\n' "$destination"
          }
          ${lib.concatMapStringsSep "\n" (artifact: ''
            ${lib.optionalString (
              artifact.warning != ""
            ) ''printf '%s\n' ${lib.escapeShellArg artifact.warning} >&2''}
            provision ${
              lib.escapeShellArgs [
                artifact.source
                artifact.destination
                artifact.contentHash
              ]
            }
          '') artifacts}
        '';
      };
      qwenArguments = [
        "--host"
        "127.0.0.1"
        "--port"
        "\${PORT}"
        "--alias"
        "\${MODEL_ID}"
        "--device"
        backend.settings.device
        "--gpu-layers"
        "99"
        "--n-cpu-moe"
        "11"
        "--fit"
        "off"
        # Standalone mlock crashes this build; mapped locking was verified.
        "--load-mode"
        "mmap+mlock"
        "--lazy-mode"
        "off"
        "--sleep-idle-seconds"
        "-1"
        "--threads"
        "12"
        "--threads-batch"
        "12"
        "--ctx-size"
        "131072"
        "--parallel"
        "1"
        "--no-kv-unified"
        "--batch-size"
        "1024"
        "--ubatch-size"
        "256"
        "--cache-type-k"
        "q8_0"
        "--cache-type-v"
        "q8_0"
        "--flash-attn"
        "on"
        "--spec-type"
        "draft-mtp"
        "--spec-draft-n-max"
        "3"
        "--spec-draft-n-min"
        "0"
        "--spec-draft-p-min"
        "0"
        "--spec-draft-n-cpu-moe"
        "11"
        "--cache-type-k-draft"
        "q8_0"
        "--cache-type-v-draft"
        "q8_0"
        "--cache-prompt"
        "--cache-ram"
        "32768"
        "--cache-idle-slots"
        "--jinja"
        "--reasoning-format"
        "deepseek"
        "--temp"
        "0.6"
        "--top-p"
        "0.95"
        "--top-k"
        "20"
        "--metrics"
        "--slots"
      ];
      # Preserve Swift's tested dense-model flags separately from REAP's MoE tuning.
      swiftArguments = [
        "--host"
        "127.0.0.1"
        "--port"
        "\${PORT}"
        "--alias"
        "\${MODEL_ID}"
        "--device"
        backend.settings.device
        "--gpu-layers"
        "99"
        "--fit"
        "off"
        "--load-mode"
        "mmap"
        "--lazy-mode"
        "off"
        "--sleep-idle-seconds"
        "-1"
        "--threads"
        "12"
        "--threads-batch"
        "12"
        "--ctx-size"
        "131072"
        "--parallel"
        "1"
        "--no-kv-unified"
        "--batch-size"
        "1024"
        "--ubatch-size"
        "256"
        "--cache-type-k"
        "q8_0"
        "--cache-type-v"
        "q8_0"
        "--flash-attn"
        "on"
        "--spec-type"
        "draft-mtp"
        "--spec-draft-n-max"
        "3"
        "--spec-draft-n-min"
        "0"
        "--spec-draft-p-min"
        "0"
        "--cache-type-k-draft"
        "q8_0"
        "--cache-type-v-draft"
        "q8_0"
        "--cache-prompt"
        "--cache-ram"
        "32768"
        "--cache-idle-slots"
        "--slot-prompt-similarity"
        "0.9"
        "--jinja"
        "--reasoning-format"
        "deepseek"
        "--temp"
        "1.0"
        "--top-p"
        "0.95"
        "--top-k"
        "20"
        "--min-p"
        "0.0"
        "--presence-penalty"
        "0.0"
        "--repeat-penalty"
        "1.0"
        "--metrics"
        "--slots"
      ];
    in
    {
      imports = [ nixos."llama-swap" ];

      services.llama-swap.settings = {
        startPort = 18081;
        routing.router = {
          use = "group";
          settings.groups.rx-7900xt = {
            # One AMD model at a time, without evicting future B50 groups.
            swap = true;
            exclusive = false;
            persistent = true;
            members = [
              "barozp-reap-q6"
              "swift15-iq3s"
            ];
          };
        };
        models.barozp-reap-q6 = {
          name = "Qwen3.6 REAP Opus Reasoning Distill MTP Q6_K";
          description = "Verified weights; one 128K slot, 11 CPU MoE layers, q8 KV and MTP. Retrieval tested through 64K input; full 128K and executor quality remain unvalidated.";
          cmd = lib.escapeShellArgs (
            [
              server
              "--model"
              qwenModel
            ]
            ++ qwenArguments
          );
          env = lib.mapAttrsToList (key: value: "${key}=${value}") backend.environment;
          proxy = "http://127.0.0.1:\${PORT}";
          useModelName = "\${MODEL_ID}";
          checkEndpoint = "/health";
          # Keep weights and RAM prompt snapshots until an explicit unload/swap.
          ttl = 0;
          timeouts = {
            connect = 30;
            keepalive = 30;
            responseHeader = 1800;
            tlsHandshake = 10;
            idleConn = 90;
          };
        };
        models.swift15-iq3s = {
          name = "Swift 1.5 Qwen3.8 27B GSQ-RCO IQ3_S MTP";
          description = "Verified weights; one 128K slot, dense GPU offload, q8 KV, MTP and tuned prompt reuse. Cold synthetic retrieval passed at 129994 input tokens; broad executor quality remains unvalidated.";
          cmd = lib.escapeShellArgs (
            [
              server
              "--model"
              swiftModel
            ]
            ++ swiftArguments
          );
          env = lib.mapAttrsToList (key: value: "${key}=${value}") backend.environment;
          proxy = "http://127.0.0.1:\${PORT}";
          useModelName = "\${MODEL_ID}";
          checkEndpoint = "/health";
          # A same-group swap still unloads this model and its RAM prompt cache.
          ttl = 0;
          timeouts = {
            connect = 30;
            keepalive = 30;
            responseHeader = 1800;
            tlsHandshake = 10;
            idleConn = 90;
          };
        };
      };

      systemd.services = {
        odin-inference-models = {
          description = "Provision Odin's explicitly selected inference artifacts";
          before = [ "llama-swap.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.getExe provisionModels;
            User = "root";
            Group = "root";
            StateDirectory = "llama-models";
            StateDirectoryMode = "0755";
            UMask = "0022";
            ProtectSystem = "strict";
            ProtectHome = "read-only";
            ReadWritePaths = [ modelRoot ];
            PrivateTmp = true;
            PrivateDevices = true;
            PrivateNetwork = true;
            NoNewPrivileges = true;
            CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
            RestrictAddressFamilies = [ "AF_UNIX" ];
          };
        };
        llama-swap = {
          requires = [ "odin-inference-models.service" ];
          after = [ "odin-inference-models.service" ];
          serviceConfig = {
            DevicePolicy = "closed";
            DeviceAllow = [ "${backend.renderDevice} rw" ];
            # Child servers inherit this, avoiding a user-manager prlimit hack.
            LimitMEMLOCK = "infinity";
          };
        };
      };
    };
}
