# modules/features/lugh-monitor.nix
{ inputs, ... }:
{
  # Read-only health checks for Hermes, as an MCP server it starts itself.
  flake.modules.nixos.hermes =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      python = pkgs.python3.withPackages (p: [ p.mcp ]);
      llama-cpp = inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.vulkan;

      # Its logs are the only ones the monitor will show.
      units = [
        "llama-swap"
        "kokoro"
        "hermes-agent"
        "hermes-backend"
        "hermes-memory"
        "obsidian-sync"
        "postgresql"
        "netbird-wt0"
        "sshd"
      ];

      # Every subvolume shares the btrfs pool on /, and /boot fills up with old generations.
      disks = [
        "/"
        "/boot"
      ];

      roles = {
        "7900 XT" = "main and the reranker";
        "B580" = "helper, or the image models";
        "Pro B50" = "worker, vision, decision, approval, embedding and transcription";
      };
    in
    {
      # The monitor's log tool reads the journal.
      users.users.hermes.extraGroups = [ "systemd-journal" ];

      services.hermes-agent.mcpServers.lugh-monitor = {
        command = "${python}/bin/python3";
        args = [
          "-I"
          "${./lugh-monitor.py}"
          "--llama-server"
          (lib.getExe' llama-cpp "llama-server")
          "--systemctl"
          "${pkgs.systemd}/bin/systemctl"
          "--journalctl"
          "${pkgs.systemd}/bin/journalctl"
          "--llama-swap-url"
          "http://127.0.0.1:${toString config.services.llama-swap.port}"
          "--memory-socket"
          config.services.hermes-agent.environment.HERMES_MEMORY_SOCKET
          "--units"
          (lib.concatStringsSep "," units)
          "--disks"
          (lib.concatStringsSep "," disks)
          "--always-loaded"
          (lib.concatStringsSep "," config.services.llama-swap.settings.hooks.on_startup.preload)
          "--roles"
          (builtins.toJSON roles)
        ];
      };
    };
}
