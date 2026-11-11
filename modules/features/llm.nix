# modules/features/llm.nix
{ inputs, ... }:
{
  flake.modules.nixos.llm =
    { lib, pkgs, ... }:
    let
      llama-cpp = inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.vulkan;
      llama-server = lib.getExe' llama-cpp "llama-server";

      mainModels = "/models/ornith-1.5-35b";
      helperModels = "/models/helpers";
      imageModels = "/models/image";

      mainDevice = "Vulkan0";
      helperDevice = "Vulkan2";
      smallModelDevice = "Vulkan1";
      # SYCL numbers only the Intel cards, so the helper's card has a different name there.
      helperSyclDevice = "SYCL1";

      oneapi = pkgs.intel-oneapi-toolkit;

      # Chroma renders only noise through Vulkan on the Arc cards, so it uses Intel's SYCL backend.
      stable-diffusion-sycl =
        (pkgs.stable-diffusion-cpp.override { stdenv = oneapi.stdenv; }).overrideAttrs
          (old: {
            pname = "stable-diffusion-cpp-sycl";
            buildInputs = (old.buildInputs or [ ]) ++ [
              oneapi
              pkgs.level-zero
            ];
            # Fortify breaks the SYCL device code, as in nixpkgs' llama.cpp SYCL build.
            hardeningDisable = [
              "fortify"
              "fortify3"
            ];
            # SYCL passes -fsycl to every target, and the video library insists on C++11, which SYCL rejects.
            cmakeFlags = (old.cmakeFlags or [ ]) ++ [
              "-DSD_SYCL=ON"
              "-DSD_WEBM=OFF"
            ];
          });

      # Vulkan numbering changes when GPUs move between slots, so startup stops if a model would land on the wrong card.
      expectedCards = {
        ${mainDevice} = "RX 7900 XT";
        ${helperDevice} = "Arc(tm) B580";
        ${smallModelDevice} = "Arc(tm) Pro B50";
      };

      checkDevices = pkgs.writeShellScript "llama-swap-check-devices" ''
        devices=$(${llama-server} --list-devices 2>&1)
        ${lib.concatStrings (
          lib.mapAttrsToList (device: card: ''
            if ! ${lib.getExe pkgs.gnugrep} -qF "${device}: " <<< "$(${lib.getExe pkgs.gnugrep} -F "${card}" <<< "$devices")"; then
              echo "Expected ${card} on ${device}. Update llm.nix to match llama-server --list-devices:" >&2
              echo "$devices" >&2
              exit 1
            fi
          '') expectedCards
        )}
        if ! ${lib.getExe' stable-diffusion-sycl "sd-cli"} --list-devices 2>&1 | ${lib.getExe pkgs.gnugrep} -F "Arc(TM) B580" | ${lib.getExe pkgs.gnugrep} -q "^${helperSyclDevice}[[:space:]]"; then
          echo "Expected the Arc B580 on ${helperSyclDevice}. Update llm.nix to match sd-cli --list-devices from the SYCL build." >&2
          exit 1
        fi
      '';

      q8Cache = "-ctk q8_0 -ctv q8_0";

      server =
        device: args:
        lib.concatStringsSep " " (
          [
            llama-server
            "--host 127.0.0.1"
            "--port \${PORT}"
            "--device ${device}"
            "-ngl 99"
            "--fit off"
            "--jinja"
          ]
          ++ args
        );

      imageServer =
        package: args:
        lib.concatStringsSep " " (
          [
            (lib.getExe' package "sd-server")
            "--listen-port \${PORT}"
            # Otherwise every request uses seed 42, and the same prompt always gives the same image.
            "--seed -1"
            # Decoding the whole image at once took a minute on the B580.
            "--vae-tiling"
          ]
          ++ args
        );

      # sd-server only listens once its model has loaded.
      imageModel = cmd: {
        inherit cmd;
        ttl = 300;
        checkEndpoint = "/";
      };
    in
    {
      environment.systemPackages = [
        llama-cpp
        pkgs.python3Packages.huggingface-hub
      ];

      # The Level Zero driver that SYCL runs on.
      hardware.graphics.extraPackages = [ pkgs.intel-compute-runtime ];

      systemd.tmpfiles.rules = [ "d /models 0775 twins users -" ];

      systemd.services.llama-swap.serviceConfig.ExecStartPre = checkDevices;

      services.llama-swap = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 8080;

        settings = {
          healthCheckTimeout = 300;
          sendLoadingState = false;

          # Clients ask for these role names, so the model behind a role can change without touching them.
          models = {
            main.cmd = server mainDevice [
              "-m ${mainModels}/Ornith-1.5-35B-A3B-Abliterated-MTPv2-APEX-I-Mini-v2D-lite.gguf"
              # A second slot lets another job run beside a chat. Both share one pool, so either can use all of it.
              "-c 262144"
              "-np 2"
              "--kv-unified"
              q8Cache
              "-ctkd q8_0 -ctvd q8_0"
              "--spec-type draft-mtp"
              "--spec-draft-n-max 2"
            ];

            helper.cmd = server helperDevice [
              "-m ${helperModels}/Ornith-1.5-9B-uncensored.Q5_K_M.gguf"
              "-c 96000"
              "-np 2"
              "--kv-unified"
              q8Cache
              "--spec-type none"
              # Thinking made its work several times slower without improving the results.
              "--reasoning off"
            ];

            # Background work nobody waits on, so it never queues ahead of the helper's.
            worker.cmd = server smallModelDevice [
              "-m ${helperModels}/Ornith-1.5-9B-uncensored.Q5_K_M.gguf"
              "-c 32000"
              "-np 2"
              "--kv-unified"
              q8Cache
              "--spec-type none"
              "--reasoning off"
            ];

            vision.cmd = server smallModelDevice [
              "-m ${helperModels}/LFM3-VL-2B-Q6_K.gguf"
              "--mmproj ${helperModels}/mmproj-LFM3-VL-2B-F16.gguf"
              "-mmdev ${smallModelDevice}"
              "-c 16384"
              "-np 1"
              "-b 4096 -ub 4096"
              "--reasoning off"
            ];

            decision.cmd = server smallModelDevice [
              "-m ${helperModels}/d1-2B-Q8_0.gguf"
              "-c 8192"
              "-np 1"
              "-b 4096 -ub 4096"
            ];

            embedding = {
              ttl = 1800;
              cmd = server smallModelDevice [
                "-m ${helperModels}/embeddinggemma-2-Q8_0.gguf"
                "--mmproj ${helperModels}/mmproj-embeddinggemma-2-BF16.gguf"
                "-mmdev ${smallModelDevice}"
                "--embedding"
                "-c 8192"
                "-np 1"
                "-b 8192 -ub 8192"
              ];
            };

            reranker = {
              ttl = 1800;
              cmd = server smallModelDevice [
                "-m ${helperModels}/Qwen3-Reranker-0.6B.Q8_0.gguf"
                "--rerank --embedding --pooling rank"
                "-c 8192"
                "-np 1"
                "-b 8192 -ub 8192"
              ];
            };

            "image-fast" = imageModel (
              imageServer pkgs.stable-diffusion-cpp-vulkan [
                "--backend ${helperDevice}"
                "-m ${imageModels}/waiNSFWIllustrious_v14.safetensors"
                "--steps 28"
                "--cfg-scale 6"
                "--sampling-method euler_a"
              ]
            );

            "image-quality" = imageModel (
              imageServer stable-diffusion-sycl [
                # The text encoder doesn't fit beside the image model, and it reads a prompt in seconds on the CPU.
                "--backend te=CPU,diffusion=${helperSyclDevice},vae=${helperSyclDevice}"
                "--diffusion-model ${imageModels}/Chroma1-HD-Flash-Q6_K.gguf"
                "--t5xxl ${imageModels}/t5-v1_1-xxl-encoder-Q8_0.gguf"
                "--vae ${imageModels}/flux-ae.safetensors"
                # Flash has guidance built in, so it needs no second pass and few steps.
                "--steps 8"
                "--sampling-method heun"
                "--cfg-scale 1"
              ]
            );
          };

          routing.router = {
            use = "group";
            settings.groups = {
              main = {
                persistent = true;
                swap = false;
                exclusive = false;
                members = [ "main" ];
              };

              helpers = {
                persistent = true;
                swap = false;
                exclusive = false;
                members = [
                  "worker"
                  "vision"
                  "decision"
                ];
              };

              # The image models need the helper's whole card. Loading one unloads the helper, which loads
              # again on its next request. Each side waits for the other's running requests to finish.
              helper-card = {
                persistent = true;
                swap = true;
                exclusive = false;
                members = [
                  "helper"
                  "image-fast"
                  "image-quality"
                ];
              };

              # Only one of these is loaded at a time, which keeps the small model GPU inside its memory budget.
              retrieval = {
                swap = true;
                exclusive = false;
                members = [
                  "embedding"
                  "reranker"
                ];
              };
            };
          };

          # The decision model loads on first use. Nothing calls it until it has an approval adapter.
          hooks.on_startup.preload = [
            "main"
            "helper"
            "worker"
            "vision"
          ];
        };
      };
    };
}
