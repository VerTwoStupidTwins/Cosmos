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

      # Both image tools use Anima, an anime and illustration model. It can't do photorealism.
      animaServer =
        model: args:
        lib.concatStringsSep " " (
          [
            (lib.getExe' pkgs.stable-diffusion-cpp-vulkan "sd-server")
            "--listen-port \${PORT}"
            "--backend ${helperDevice}"
            "--diffusion-model ${imageModels}/${model}"
            "--llm ${imageModels}/qwen_3_06b_base.safetensors"
            "--vae ${imageModels}/qwen_image_vae.safetensors"
            # Every request starts from these settings, but its prompt replaces the default one, so only the negative prompt can be set here.
            ''-n "worst quality, low quality, score_1, score_2, score_3, artist name, blurry, jpeg artifacts, chromatic aberration"''
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

            # About 30 seconds for a square image. Turbo is distilled, so it needs few steps and no second pass.
            "image-fast" = imageModel (
              animaServer "anima-turbo-v1.1.safetensors" [
                "--steps 10"
                "--cfg-scale 1"
                "--sampling-method euler"
              ]
            );

            # About 2 minutes for a square image, and sharper and more detailed than Turbo.
            "image-quality" = imageModel (
              animaServer "anima-aesthetic-v1.1.safetensors" [
                "--steps 30"
                "--cfg-scale 4.5"
                "--sampling-method er_sde"
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
