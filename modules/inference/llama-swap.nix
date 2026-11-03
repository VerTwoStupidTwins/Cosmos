{ ... }:
{
  flake.nixosModules.llamaSwap =
    { config, lib, ... }:
    let
      llamaServer = lib.getExe' config.services.llama-cpp.package "llama-server";

      modelPath = "/srv/models/qwen36-heretic/Qwen3.6-35B-A3B-uncensored-heretic-Native-MTP-Preserved-APEX-I-Compact.gguf";
    in
    {
      services.llama-swap = {
        enable = true;

        listenAddress = "0.0.0.0";
        port = 8080;
        openFirewall = false;

        settings = {
          healthCheckTimeout = 600;
          logLevel = "info";
          logToStdout = "both";
          startPort = 18081;

          models."qwen36-heretic" = {
            # Unload after ten idle minutes.
            ttl = 600;

            proxy = "http://127.0.0.1:\${PORT}";

            env = [
              "VK_LOADER_DRIVERS_SELECT=*radeon"
            ];

            cmd = ''
              ${llamaServer}
              --model ${lib.escapeShellArg modelPath}
              --split-mode none
              --n-gpu-layers 99
              --n-cpu-moe 0
              --threads 12
              --batch-size 2048
              --ubatch-size 512
              --flash-attn on
              --ctx-size 131072
              --parallel 1
              --fit off
              --cache-type-k q8_0
              --cache-type-v q8_0
              --spec-type draft-mtp
              --spec-draft-n-max 3
              --spec-draft-p-min 0
              --spec-draft-type-k f16
              --spec-draft-type-v f16
              --jinja
              --reasoning on
              --reasoning-budget 4096
              --temp 0.6
              --top-p 0.95
              --top-k 20
              --min-p 0
              --presence-penalty 0.0
              --repeat-penalty 1.0
              --host 127.0.0.1
              --port ''${PORT}
            '';
          };
        };
      };

      networking.firewall.interfaces."wt0".allowedTCPPorts = [
        8080
      ];

      systemd.services.llama-swap = {
        unitConfig.RequiresMountsFor = [
          "/srv/models"
        ];

        environment.LD_LIBRARY_PATH = "/run/opengl-driver/lib";

        serviceConfig = {
          SupplementaryGroups = [
            "render"
            "video"
          ];

          PrivateUsers = lib.mkForce false;
          MemoryDenyWriteExecute = lib.mkForce false;
        };
      };
    };
}
