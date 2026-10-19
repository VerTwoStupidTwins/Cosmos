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
      lfmModel = "${modelRoot}/lfm25-heretic-b7ee8c913ca1/LFM2.5-24B-A2B-Uncensored-Heretic.Q4_K_M.gguf";
      qwenModel = "${modelRoot}/qwen36-apex-unverified-313e55f61a04/Qwen3.6-35B-A3B-uncensored-heretic-Native-MTP-Preserved-APEX-I-Balanced.gguf";
      artifacts = [
        {
          source = "/home/twins/.local/share/cosmos-models/lfm25-heretic/b7ee8c913ca1aaa7ecf12e6290f8310497a55fef/LFM2.5-24B-A2B-Uncensored-Heretic.Q4_K_M.gguf";
          destination = lfmModel;
          contentHash = "ee5faa7526b18bf7a8b72a6813a73bc8b2d5b76c4e638bc7858d9106df9487ef";
          warning = "";
        }
        {
          source = "/home/twins/.local/share/cosmos-models/qwen36-apex/313e55f61a045dd18ac023d28fe845ee35988a5d/Qwen3.6-35B-A3B-uncensored-heretic-Native-MTP-Preserved-APEX-I-Balanced.gguf";
          destination = qwenModel;
          # Pin the explicitly approved local bytes, NOT the publisher hash.
          contentHash = "d4f7590f002c46f8d1acedf117d247a91aa4760ea92d60fc966867eac79cf02c";
          warning = "UNVERIFIED Qwen: publisher SHA-256 782636c45124fd40bf55254f802aba3b6c14e53d36f7a60f724f332761e9aa89 does not match the approved testing file d4f7590f002c46f8d1acedf117d247a91aa4760ea92d60fc966867eac79cf02c.";
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
      commonArguments = [
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
        "--threads"
        "12"
        "--threads-batch"
        "12"
        "--batch-size"
        "512"
        "--ubatch-size"
        "128"
        "--cache-type-k"
        "f16"
        "--cache-type-v"
        "f16"
        "--jinja"
        "--metrics"
        "--reasoning-format"
        "deepseek"
      ];
      model = path: arguments: {
        cmd = lib.escapeShellArgs (
          [
            server
            "--model"
            path
          ]
          ++ commonArguments
          ++ arguments
        );
        env = lib.mapAttrsToList (key: value: "${key}=${value}") backend.environment;
        proxy = "http://127.0.0.1:\${PORT}";
        useModelName = "\${MODEL_ID}";
        checkEndpoint = "/health";
      };
    in
    {
      imports = [ nixos."llama-swap" ];

      services.llama-swap.settings = {
        startPort = 18081;
        # The default scheduler permits one resident model. Do not add a set
        # allowing these two AMD models to remain loaded together.
        models = {
          lfm25-heretic-q4 =
            (model lfmModel [
              "--ctx-size"
              "262144"
              "--parallel"
              "2"
              "--n-cpu-moe"
              "0"
              "--spec-type"
              "none"
            ])
            // {
              name = "LFM2.5 Heretic Q4_K_M";
              description = "Verified weights; two 128K slots. Experimental: 120K-input retrieval failed in repeated testing.";
              aliases = [ "lfm" ];
            };
          qwen36-apex-balanced-unverified =
            (model qwenModel [
              "--ctx-size"
              "65536"
              "--parallel"
              "2"
              "--n-cpu-moe"
              "16"
              "--spec-type"
              "draft-mtp"
              "--spec-draft-n-max"
              "2"
              "--spec-draft-n-cpu-moe"
              "16"
            ])
            // {
              name = "Qwen3.6 APEX-I-Balanced (UNVERIFIED)";
              description = "UNVERIFIED: downloaded weights fail the publisher SHA-256. Explicitly approved for further testing only; two 32K slots, CPU expert offload and MTP.";
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
          };
        };
      };
    };
}
