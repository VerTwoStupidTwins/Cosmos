# modules/features/llm.nix
{ inputs, ... }:
{
  flake.modules.nixos.llm =
    { lib, pkgs, ... }:
    let
      llama-cpp = inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.vulkan;
      llama-server = lib.getExe' llama-cpp "llama-server";

      mainModels = "/models/qwen3.8-27b";
      helperModels = "/models/helpers";

      # Vulkan numbering can change when a GPU is added: recheck with `llama-server --list-devices`.
      mainDevice = "Vulkan0"; # RX 7900 XT
      helperDevice = "Vulkan1"; # Arc Pro B50

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
    in
    {
      environment.systemPackages = [
        llama-cpp
        pkgs.python3Packages.huggingface-hub
      ];

      systemd.tmpfiles.rules = [ "d /models 0775 twins users -" ];

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
              "-m ${mainModels}/Swift-1.5-Qwen3.8-27B-Uncensored-VAL-APEX-I-NanoPlus-V3.gguf"
              "-c 128000"
              "-np 1"
              q8Cache
              "-ctkd q8_0 -ctvd q8_0"
              "--spec-type draft-mtp"
              "--spec-draft-n-max 2"
            ];

            helper.cmd = server helperDevice [
              "-m ${helperModels}/Qwen3.8-9B-heretic-uncensored.Q5_K_M.gguf"
              "-c 64000"
              "-np 2"
              "--kv-unified"
              q8Cache
              "--spec-type none"
            ];

            vision.cmd = server helperDevice [
              "-m ${helperModels}/LFM3-VL-2B-Q6_K.gguf"
              "--mmproj ${helperModels}/mmproj-LFM3-VL-2B-F16.gguf"
              "-mmdev ${helperDevice}"
              "-c 16384"
              "-np 1"
              "-b 4096 -ub 4096"
              "--reasoning off"
            ];

            decision.cmd = server helperDevice [
              "-m ${helperModels}/d1-2B-Q8_0.gguf"
              "-c 8192"
              "-np 1"
              "-b 4096 -ub 4096"
            ];

            embedding = {
              ttl = 1800;
              cmd = server helperDevice [
                "-m ${helperModels}/embeddinggemma-2-Q8_0.gguf"
                "--mmproj ${helperModels}/mmproj-embeddinggemma-2-BF16.gguf"
                "-mmdev ${helperDevice}"
                "--embedding"
                "-c 8192"
                "-np 1"
                "-b 8192 -ub 8192"
              ];
            };

            reranker = {
              ttl = 1800;
              cmd = server helperDevice [
                "-m ${helperModels}/Qwen3-Reranker-0.6B.Q8_0.gguf"
                "--rerank --embedding --pooling rank"
                "-c 8192"
                "-np 1"
                "-b 8192 -ub 8192"
              ];
            };
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
                  "helper"
                  "vision"
                  "decision"
                ];
              };

              # Only one of these is loaded at a time, which keeps the helper GPU inside its memory budget.
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

          hooks.on_startup.preload = [
            "main"
            "helper"
            "vision"
            "decision"
          ];
        };
      };
    };
}
