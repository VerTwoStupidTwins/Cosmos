# Odin's Vulkan reasoning / shared SYCL B50 roster; standalone instances stay off.
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
      intelBackend = config.services.llama-cpp-instances.intel;
      intelServer = lib.getExe' intelBackend.package "llama-server";
      intelEnvironment = lib.mapAttrsToList (key: value: "${key}=${value}") (
        intelBackend.environment
        // {
          ONEDNN_DEFAULT_FPMATH_MODE = "STRICT";
          DNNL_DEFAULT_FPMATH_MODE = "STRICT";
        }
      );
      modelRoot = "/var/lib/llama-models";
      embeddingRoot = "${modelRoot}/embeddinggemma2-031f0d4b3553";
      embeddingSource = "/home/twins/.local/share/cosmos-models/embeddinggemma2/031f0d4b35536f69ab3509d4893c923264fcf253";
      gemmaRoot = "${modelRoot}/gemma4-hauhau-balanced-mtp-f9093662a2e7";
      gemmaSource = "/home/twins/.local/share/cosmos-models/gemma4-hauhau-balanced-mtp/f9093662a2e7ae0503f637088bc96f77a1a70c83";
      gemmaModel = "${gemmaRoot}/Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-Q4_K_M.gguf";
      gemmaProjector = "${gemmaRoot}/mmproj-Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-BF16.gguf";
      gemmaDraft = "${gemmaRoot}/mtp-gemma-4-26B-A4B-it.gguf";
      clefModel = "${modelRoot}/clef-flash-8aa35d1cc7e1/Clef-Flash-Q8_0.gguf";
      artifacts = [
        {
          source = "/home/twins/.local/share/cosmos-models/clef-flash/8aa35d1cc7e141f3771e564eeb630a501597c681/Clef-Flash-Q8_0.gguf";
          destination = clefModel;
          contentHash = "87a232aa1f7495cfc90ce22f08bb3779655e1b05c991c84b21afa4c1c8c4e0f5";
          warning = "";
        }
        {
          source = "${embeddingSource}/embeddinggemma-2-Q8_0.gguf";
          destination = "${embeddingRoot}/embeddinggemma-2-Q8_0.gguf";
          contentHash = "6f1bd4ac6c5df7444f9cca7ca36cafe6cfa34cd6f49fefb1e0b4be8143aed8bc";
          warning = "";
        }
        {
          source = "${embeddingSource}/mmproj-BF16.gguf";
          destination = "${embeddingRoot}/mmproj-BF16.gguf";
          contentHash = "995aaa56e88b9b631f651861d659b728a625ccc02a238be37cff56cf11dc0032";
          warning = "";
        }
        {
          source = "${gemmaSource}/Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-Q4_K_M.gguf";
          destination = gemmaModel;
          contentHash = "3c13133469e431312fffb8b1d9c85ae42199e6bb5746ea1da84e8ddf2097d73c";
          warning = "";
        }
        {
          source = "${gemmaSource}/mmproj-Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-BF16.gguf";
          destination = gemmaProjector;
          contentHash = "b5346e5bfd906f5e16878c2d0b8243e948ca7410fa28ea35be9b0c54a0ac10b7";
          warning = "";
        }
        {
          source = "${gemmaSource}/mtp-gemma-4-26B-A4B-it.gguf";
          destination = gemmaDraft;
          contentHash = "62bd3af7f66c9308de9a5454233852f8c7324c93767e8dfb824ed45b9179864a";
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
      clefArguments = [
        "--host"
        "127.0.0.1"
        "--port"
        "\${PORT}"
        "--alias"
        "\${MODEL_ID}"
        "--model"
        clefModel
        "--device"
        intelBackend.settings.device
        "--n-gpu-layers"
        "99"
        "--fit"
        "off"
        "--ctx-size"
        "4096"
        "--parallel"
        "1"
        "--batch-size"
        "4096"
        "--ubatch-size"
        "4096"
        "--threads"
        "4"
        "--threads-batch"
        "4"
        "--cache-type-k"
        "f32"
        "--cache-type-v"
        "f32"
        "--flash-attn"
        "off"
        "--sleep-idle-seconds"
        "-1"
        "--slots"
        "--metrics"
      ];
      embeddingArguments = [
        "--host"
        "127.0.0.1"
        "--port"
        "\${PORT}"
        "--alias"
        "\${MODEL_ID}"
        "--model"
        "${embeddingRoot}/embeddinggemma-2-Q8_0.gguf"
        "--mmproj"
        "${embeddingRoot}/mmproj-BF16.gguf"
        "--device"
        intelBackend.settings.device
        "--mmproj-device"
        intelBackend.settings.device
        "--mmproj-offload"
        "--n-gpu-layers"
        "99"
        "--fit"
        "off"
        "--embedding"
        "--pooling"
        "mean"
        "--ctx-size"
        "8192"
        "--parallel"
        "1"
        "--batch-size"
        "8192"
        "--ubatch-size"
        "8192"
        "--threads"
        "4"
        "--threads-batch"
        "4"
        "--cache-type-k"
        "f32"
        "--cache-type-v"
        "f32"
        "--flash-attn"
        "off"
        "--video-ffmpeg-dir"
        "${pkgs.ffmpeg}/bin"
        "--sleep-idle-seconds"
        "-1"
        "--slots"
        "--metrics"
      ];
      # Tested GPU-balanced profile; non-causal image input is capped by microbatch.
      gemmaArguments = [
        "--host"
        "127.0.0.1"
        "--port"
        "\${PORT}"
        "--alias"
        "\${MODEL_ID}"
        "--model"
        gemmaModel
        "--device"
        backend.settings.device
        "--gpu-layers"
        "99"
        "--fit"
        "off"
        "--load-mode"
        "mmap"
        "--ctx-size"
        "131072"
        "--parallel"
        "1"
        "--batch-size"
        "512"
        "--ubatch-size"
        "256"
        "--threads"
        "12"
        "--threads-batch"
        "12"
        "--cache-type-k"
        "q8_0"
        "--cache-type-v"
        "q8_0"
        "--flash-attn"
        "on"
        "--model-draft"
        gemmaDraft
        "--spec-type"
        "draft-mtp"
        "--spec-draft-n-max"
        "3"
        "--device-draft"
        backend.settings.device
        "--spec-draft-ngl"
        "99"
        "--cache-type-k-draft"
        "q8_0"
        "--cache-type-v-draft"
        "q8_0"
        "--jinja"
        "--chat-template-kwargs"
        "{\"enable_thinking\":true}"
        "--temp"
        "0.6"
        "--top-k"
        "64"
        "--top-p"
        "0.9"
        "--min-p"
        "0.05"
        "--repeat-penalty"
        "1.1"
        "--metrics"
        "--slots"
        "--mmproj"
        gemmaProjector
        "--mmproj-device"
        backend.settings.device
        "--mmproj-offload"
        "--cache-prompt"
        "--cache-ram"
        "8192"
        "--cache-idle-slots"
      ];
    in
    {
      imports = [ nixos."llama-swap" ];

      # Keep localhost usable; remote ingress is allowed only through NetBird.
      services.llama-swap.listenAddress = "0.0.0.0";
      networking.firewall.interfaces.wt0.allowedTCPPorts = [ config.services.llama-swap.port ];

      services.llama-swap.settings = {
        startPort = 18081;
        hooks.on_startup.preload = [
          "embeddinggemma2"
          "clef-flash-q8"
        ];
        routing.router = {
          use = "group";
          settings.groups.intel-b50 = {
            swap = false;
            exclusive = false;
            persistent = true;
            members = [
              "embeddinggemma2"
              "clef-flash-q8"
            ];
          };
          settings.groups.rx-7900xt = {
            # Keep Radeon reasoning isolated from the resident B50 models.
            swap = true;
            exclusive = false;
            persistent = true;
            members = [ "gemma4-balanced-q4" ];
          };
        };
        models = {
          clef-flash-q8 = {
            name = "Clef-Flash 9B Q8_0 decisions";
            description = "B50 FP16 SYCL native decisions; one 4K input slot, full GPU offload and attention off. Text-only audition and short embedding co-residency test passed; GPT workflow savings and production confidence calibration remain unvalidated.";
            cmd = lib.escapeShellArgs ([ intelServer ] ++ clefArguments);
            env = intelEnvironment;
            proxy = "http://127.0.0.1:\${PORT}";
            useModelName = "\${MODEL_ID}";
            checkEndpoint = "/health";
            ttl = 0;
            timeouts = {
              connect = 30;
              keepalive = 30;
              responseHeader = 1800;
              tlsHandshake = 10;
              idleConn = 90;
            };
          };
          embeddinggemma2 = {
            name = "EmbeddingGemma 2 Q8_0 + BF16 media projector";
            description = "B50 shared FP16 SYCL embeddings; one 8K slot, 768 dimensions, mean pooling, f32 KV and attention off. Text retrieval, numerical media controls and short Clef co-residency tested; real-media retrieval and native video remain unvalidated.";
            cmd = lib.escapeShellArgs ([ intelServer ] ++ embeddingArguments);
            env = intelEnvironment;
            proxy = "http://127.0.0.1:\${PORT}";
            useModelName = "\${MODEL_ID}";
            checkEndpoint = "/health";
            ttl = 0;
            timeouts = {
              connect = 30;
              keepalive = 30;
              responseHeader = 1800;
              tlsHandshake = 10;
              idleConn = 90;
            };
          };
          gemma4-balanced-q4 = {
            name = "Gemma4 26B A4B HauhauCS Balanced Q4_K_M MTP + vision";
            description = "Tested GPU-balanced profile: one 128K slot, Q8 KV, MTP max 3 and GPU vision capped to 256 image tokens by microbatch. Synthetic mixed retrieval passed at 125879 input tokens; peak VRAM 19.761 GiB leaves only 0.223 GiB headroom. Broad executor quality and production resilience remain unvalidated.";
            cmd = lib.escapeShellArgs ([ server ] ++ gemmaArguments);
            env = lib.mapAttrsToList (key: value: "${key}=${value}") backend.environment;
            proxy = "http://127.0.0.1:\${PORT}";
            useModelName = "\${MODEL_ID}";
            checkEndpoint = "/health";
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
            DeviceAllow = [
              "${backend.renderDevice} rw"
              "${intelBackend.renderDevice} rw"
            ];
            # Override upstream's non-default true: oneDNN needs JIT, and the
            # proxy and its children necessarily share this sandbox setting.
            MemoryDenyWriteExecute = lib.mkForce false;
            # Child servers inherit this, avoiding a user-manager prlimit hack.
            LimitMEMLOCK = "infinity";
          };
        };
      };
    };
}
