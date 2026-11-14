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
      voiceModels = "/models/voice";

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

      mossModels = "${imageModels}/moss";

      # sd-server only listens once its model has loaded.
      imageModel = cmd: {
        inherit cmd;
        ttl = 300;
        checkEndpoint = "/";
      };

      kokoroPython = pkgs.python3.withPackages (p: [
        p.kokoro
        # Kokoro's text processing would otherwise try to download this when it starts.
        p.spacy-models.en_core_web_sm
      ]);
    in
    {
      environment.systemPackages = [
        llama-cpp
        pkgs.python3Packages.huggingface-hub
      ];

      systemd.tmpfiles.rules = [ "d /models 0775 twins users -" ];

      systemd.services.llama-swap = {
        serviceConfig.ExecStartPre = checkDevices;
        # whisper-server converts voice messages to WAV with it.
        path = [ pkgs.ffmpeg-headless ];
      };

      # Speech for Hermes' replies. It runs on the CPU and stays loaded, so replies don't wait for it to load.
      # It's a service of its own because PyTorch compiles code at runtime, which llama-swap's sandbox forbids.
      systemd.services.kokoro = {
        description = "Kokoro speech server";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        environment = {
          HF_HUB_OFFLINE = "1";
          HOME = "/var/cache/kokoro";
          XDG_CACHE_HOME = "/var/cache/kokoro";
        };
        serviceConfig = {
          ExecStart = lib.concatStringsSep " " [
            "${kokoroPython}/bin/python3 -I ${./kokoro-server.py}"
            "--port 8880"
            "--model-dir ${voiceModels}/kokoro"
            "--ffmpeg ${lib.getExe pkgs.ffmpeg-headless}"
          ];
          Restart = "on-failure";
          DynamicUser = true;
          CacheDirectory = "kokoro";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictNamespaces = true;
          LockPersonality = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          IPAddressAllow = "localhost";
          IPAddressDeny = "any";
        };
      };

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

            # Reads the images the owner sends. Q4_K_M is the largest quant that fits the B50 beside its other
            # models: with all of them loaded, about 1 GB stays free during a request.
            vision.cmd = server smallModelDevice [
              "-m ${helperModels}/qwen3.5-9b/Qwen3.5-9B-Q4_K_M.gguf"
              "--mmproj ${helperModels}/qwen3.5-9b/mmproj-F16.gguf"
              "-mmdev ${smallModelDevice}"
              "-c 16384"
              "-np 1"
              "-b 4096 -ub 4096"
              "--reasoning off"
            ];

            # Judges flagged commands for Hermes, through the approval adapter.
            decision.cmd = server smallModelDevice [
              "-m ${helperModels}/d1-2B-Q8_0.gguf"
              "-c 8192"
              "-np 1"
              "-b 4096 -ub 4096"
            ];

            # Hermes asks for a one-word verdict over chat, and the decision model answers through /v1/systemone.
            approval.cmd = lib.concatStringsSep " " [
              "${pkgs.python3}/bin/python3 -I ${./approval-adapter.py}"
              "--port \${PORT}"
              "--decision-url http://127.0.0.1:8080/upstream/decision"
            ];

            # Every memory and wiki search embeds, so this stays loaded.
            embedding.cmd = server smallModelDevice [
              "-m ${helperModels}/embeddinggemma-2-Q8_0.gguf"
              "--mmproj ${helperModels}/mmproj-embeddinggemma-2-BF16.gguf"
              "-mmdev ${smallModelDevice}"
              "--embedding"
              "-c 8192"
              "-np 1"
              # A whole text must fit in one batch, and a text can be up to 8192 tokens.
              "-b 8192 -ub 8192"
            ];

            # Orders memory and wiki search results, beside the embedding model so neither ever swaps. Reranking
            # 30 sections takes about 0.9 s here, against 0.36 s on the 7900 XT, which keeps that card for main.
            reranker.cmd = server smallModelDevice [
              "-m ${helperModels}/Qwen3-Reranker-0.6B.Q8_0.gguf"
              "--rerank --embedding --pooling rank"
              "-c 4096"
              "-np 1"
              # A query and one wiki section fit in one batch.
              "-b 2048 -ub 2048"
            ];

            # Transcribes voice messages in about a second. It stays loaded, so the first message after a quiet
            # stretch doesn't wait for it to load.
            transcription = {
              checkEndpoint = "/";
              cmd = lib.concatStringsSep " " [
                (lib.getExe' pkgs.whisper-cpp-vulkan "whisper-server")
                "--host 127.0.0.1"
                "--port \${PORT}"
                # whisper.cpp takes the Vulkan device's number alone.
                "--device ${lib.removePrefix "Vulkan" smallModelDevice}"
                "-m ${voiceModels}/ggml-large-v3-turbo-q8_0.bin"
                "--language en"
                "--inference-path /v1/audio/transcriptions"
                # Telegram sends voice messages as Ogg, which whisper-server reads only after converting.
                "--convert"
              ];
            };

            # MOSS-Image SFT draws photos and illustration, and isn't censored. It needs the main card, so
            # loading it unloads main, which loads again in about 5 seconds on its next request.
            # These defaults take about 3 minutes for a square image. Hermes' quick tool adds an 8-step LoRA
            # from ${mossModels}/loras to its requests, which takes about 25 seconds.
            image = imageModel (
              lib.concatStringsSep " " [
                (lib.getExe' pkgs.stable-diffusion-cpp-vulkan "sd-server")
                "--listen-port \${PORT}"
                "--backend ${mainDevice}"
                "--diffusion-model ${mossModels}/MOSS-Image-SFT-Q8_0.gguf"
                "--llm ${mossModels}/Qwen3.5-9B-Q8_0.gguf"
                "--vae ${mossModels}/vae/flux2-vae.safetensors"
                # Qwen3.5's vocabulary differs from the tokenizer built into stable-diffusion.cpp.
                "--tokenizer ${mossModels}/tokenizer/tokenizer.json"
                # The upstream defaults. stable-diffusion.cpp applies the matching shift and layer skip itself.
                "--steps 50"
                "--cfg-scale 3"
                "--sampling-method euler"
                # Otherwise every request uses seed 42, and the same prompt always gives the same image.
                "--seed -1"
              ]
            );
          };

          routing.router = {
            use = "group";
            settings.groups = {
              # The image model needs main's card. Each side waits for the other's running requests to finish.
              main-card = {
                persistent = true;
                swap = true;
                exclusive = false;
                members = [
                  "main"
                  "image"
                ];
              };

              helpers = {
                persistent = true;
                swap = false;
                exclusive = false;
                members = [
                  "vision"
                  "decision"
                  "approval"
                  "transcription"
                ];
              };

              helper-card = {
                persistent = true;
                swap = false;
                exclusive = false;
                members = [ "helper" ];
              };

              # Memory and wiki searches use both on every query, so they stay loaded side by side.
              retrieval = {
                persistent = true;
                swap = false;
                exclusive = false;
                members = [
                  "embedding"
                  "reranker"
                ];
              };
            };
          };

          # Every flagged command waits on an approval, so those models never wait to load.
          hooks.on_startup.preload = [
            "main"
            "helper"
            "vision"
            "embedding"
            "reranker"
            "decision"
            "approval"
            "transcription"
          ];
        };
      };
    };
}
