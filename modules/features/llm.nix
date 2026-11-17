# modules/features/llm.nix
{ inputs, ... }:
{
  flake.modules.nixos.llm =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      # llama-swap talks to the API only, so the server's web UI is left out. Its build broke upstream on
      # 2026-11-14 when it started importing a llama-brand module that the Nix build doesn't fetch.
      llama-cpp =
        (inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.vulkan.override { useWebUi = false; })
        .overrideAttrs
          { webui = null; };
      llama-server = lib.getExe' llama-cpp "llama-server";

      # Vulkan on the Intel cards slows sharply on long prompts: 40,000 tokens into a chat, the helper read 248
      # tokens a second and wrote 23, against 1,471 and 45 with SYCL. That made Hermes' compressions stall
      # past its 900-second limit. The B50's models gave the same answers on both. The llama.cpp flake has
      # no SYCL build, so this is nixpkgs' package on the same source, without the web UI and the tests,
      # which need PyTorch.
      llama-cpp-sycl = (pkgs.llama-cpp.override { syclSupport = true; }).overrideAttrs (old: {
        src = inputs.llama-cpp;
        version = "0-unstable-${inputs.llama-cpp.shortRev}";
        doCheck = false;
        nativeBuildInputs = builtins.filter (
          p: !(lib.hasPrefix "nodejs" (p.pname or p.name or "")) && (p.name or "") != "npm-config-hook"
        ) old.nativeBuildInputs;
        npmDeps = null;
        preConfigure = "";
        cmakeFlags = old.cmakeFlags ++ [
          "-DLLAMA_BUILD_WEBUI=OFF"
          "-DGGML_SYCL_F16=ON"
        ];
      });
      sycl-server = lib.getExe' llama-cpp-sycl "llama-server";

      # Intel's Level Zero and OpenCL drivers, which SYCL reaches the cards through.
      syclEnv = [
        "LD_LIBRARY_PATH=${pkgs.intel-compute-runtime}/lib"
        "OCL_ICD_VENDORS=${pkgs.intel-compute-runtime}/etc/OpenCL/vendors"
      ];

      mainModels = "/models/minicpm-v-4.7-apex";
      helperModels = "/models/helpers";
      voiceModels = "/models/voice";

      # SYCL numbers only the Intel cards.
      mainDevice = "Vulkan0";
      helperDevice = "SYCL1";
      smallModelDevice = "SYCL0";
      # whisper.cpp has no SYCL build in nixpkgs, so transcription stays on Vulkan.
      transcriptionDevice = "Vulkan1";

      # Numbering changes when GPUs move between slots, so startup stops if a model would land on the wrong card.
      # Cards by their short names in gpu.nix, which --list-devices includes in each card's name.
      expectedCards = {
        ${mainDevice} = "7900 XT";
        ${helperDevice} = "B580";
        ${smallModelDevice} = "Pro B50";
        ${transcriptionDevice} = "Pro B50";
      };
      card =
        device:
        assert config.monitor.cards ? ${expectedCards.${device}};
        expectedCards.${device};

      checkDevices = pkgs.writeShellScript "llama-swap-check-devices" ''
        devices=$(${llama-server} --list-devices 2>&1; env ${lib.escapeShellArgs syclEnv} ${sycl-server} --list-devices 2>&1)
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

      sycl = lib.hasPrefix "SYCL";

      server =
        device: args:
        {
          cmd = lib.concatStringsSep " " (
            [
              (if sycl device then sycl-server else llama-server)
              "--host 127.0.0.1"
              "--port \${PORT}"
              "--device ${device}"
              "-ngl 99"
              "--fit off"
              "--jinja"
            ]
            ++ args
          );
        }
        // lib.optionalAttrs (sycl device) { env = syclEnv; };

      # MOSS-Image in ComfyUI's single-file formats, from Comfy-Org/MOSS-Image, and the community 8-step LoRA.
      comfyuiUrl = "http://127.0.0.1:8188";

      kokoroPort = 8880;

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

      monitor = {
        units = [
          "llama-swap"
          "kokoro"
        ];
        ports = {
          llama-swap = config.services.llama-swap.port;
          kokoro = kokoroPort;
        };
        models = {
          main = card mainDevice;
          helper = card helperDevice;
          decision = card smallModelDevice;
          embedding = card smallModelDevice;
          reranker = card smallModelDevice;
          transcription = card transcriptionDevice;
        };
        inherit checkDevices;
        llamaServer = llama-server;
        llamaSwapUrl = "http://127.0.0.1:${toString config.services.llama-swap.port}";
      };

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
            "--port ${toString kokoroPort}"
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
            main = server mainDevice [
              # MiniCPM-V 4.7 35B-A3B, abliterated. It sees images itself through its projector, also on this card.
              # It has no MTP head, and OpenBMB's DSpark draft accepted only about 12% of drafts on this abliterated
              # build, so it drafts from n-grams already in the context instead.
              "-m ${mainModels}/MiniCPM-V-4.7-35B-A3B-Abliterated.APEX-I-MiniPlus-V2.1.gguf"
              "--mmproj ${mainModels}/mmproj-Q8_0.gguf"
              # A second slot lets another job run beside a chat. Both share one pool, so either can use all of it.
              "-c 262144"
              "-np 2"
              "--kv-unified"
              q8Cache
              # Larger batches read long prompts faster. With them the card has about 1.7 GB free.
              "-b 4096 -ub 2048"
              # Rewriting a file it was given ran 3.8 times faster, and quoting a log 11% faster. Output with
              # nothing to copy is unaffected. ngram-simple quoted faster but slowed JSON output by a quarter.
              "--spec-type ngram-mod"
              # Its recurrent layers can only resume a prompt from a saved checkpoint, not from any token. More
              # RAM for cached prompts and closer checkpoints let long chats and background jobs resume from
              # cache more often instead of reading tens of thousands of tokens again. The defaults are 8 GB
              # and a checkpoint every 8192 tokens.
              "--cache-ram 32768"
              "-cms 4096"
            ];

            helper = server helperDevice [
              "-m ${helperModels}/Ornith-1.5-9B-uncensored.Q5_K_M.gguf"
              "-c 96000"
              "-np 2"
              "--kv-unified"
              q8Cache
              "--spec-type none"
              # Thinking made its work several times slower without improving the results.
              "--reasoning off"
            ];

            # Judges flagged commands for Hermes, through the approval adapter.
            decision = server smallModelDevice [
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
            embedding = server smallModelDevice [
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
            reranker = server smallModelDevice [
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
                "--device ${lib.removePrefix "Vulkan" transcriptionDevice}"
                "-m ${voiceModels}/ggml-large-v3-turbo-q8_0.bin"
                "--language en"
                "--inference-path /v1/audio/transcriptions"
                # Telegram sends voice messages as Ogg, which whisper-server reads only after converting.
                "--convert"
              ];
            };

            # MOSS-Image SFT draws photos and illustration, and isn't censored. It runs in ComfyUI on the B580, which
            # this adapter borrows from the helper: loading it stops the helper, and stopping it unloads ComfyUI's
            # models. A fast image takes about 20 seconds and a 25-step one about 85.
            image = {
              cmd = lib.concatStringsSep " " [
                "${pkgs.python3}/bin/python3 -I ${./comfyui-adapter.py}"
                "--port \${PORT}"
                "--comfyui-url ${comfyuiUrl}"
                "--diffusion-model moss_image_sft_int8_convrot.safetensors"
                "--text-encoder qwen3.5_9b_w4a8_gptq.safetensors"
                "--vae flux2-vae_small.safetensors"
                "--fast-lora moss-image-sft-8step-dmd.safetensors"
              ];
              checkEndpoint = "/health";
              # Gives the card back to the helper after five idle minutes.
              ttl = 300;
            };
          };

          routing.router = {
            use = "group";
            settings.groups = {
              main-card = {
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
                  "decision"
                  "approval"
                  "transcription"
                ];
              };

              # Images borrow the helper's card. Each side waits for the other's running requests to finish.
              helper-card = {
                persistent = true;
                swap = true;
                exclusive = false;
                members = [
                  "helper"
                  "image"
                ];
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
