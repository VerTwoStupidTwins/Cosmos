# modules/features/lugh-monitor.nix
{ inputs, ... }:
{
  # Read-only health checks and config lookups for Hermes, as an MCP server it starts itself.
  flake.modules.nixos.hermes =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      monitor = pkgs.rustPlatform.buildRustPackage {
        pname = "lugh-monitor";
        version = "0.1.0";
        src = ./lugh-monitor;
        cargoLock.lockFile = ./lugh-monitor/Cargo.lock;
        meta.mainProgram = "lugh-monitor";
      };

      # The same build as llm.nix, which explains the missing web UI.
      llama-cpp = (inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.vulkan.override { useWebUi = false; }).overrideAttrs { webui = null; };

      # The config this system was built from, for the config tools. Secrets stay out, and so do the wallpapers.
      configSource = lib.fileset.toSource {
        root = ../..;
        fileset = lib.fileset.intersection (lib.fileset.unions [
          ../../flake.nix
          ../../flake.lock
          ../../modules
        ]) (lib.fileset.fileFilter (file: !lib.any file.hasExt [ "png" "jpg" "jpeg" "webp" "gif" ]) ../..);
      };

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
        "7900 XT" = "main, or the image model in its place";
        "B580" = "helper, which also picks out memories after each chat turn";
        "Pro B50" = "decision, approval, embedding, reranker and transcription";
      };
    in
    {
      # The monitor's log tool reads the journal.
      users.users.hermes.extraGroups = [ "systemd-journal" ];

      # The monitor reads these on every call, so it describes whichever system is active, even though Hermes keeps
      # running across switches. As arguments, they'd also rewrite Hermes' config with every commit.
      environment.etc = {
        "lugh-monitor/revision".text = lib.defaultTo "unknown" config.system.configurationRevision;
        "lugh-monitor/config".source = configSource;
        # Files the config manages in Hermes' home that come from the repo, so Hermes' edits to them can be found.
        "lugh-monitor/managed-files.json".text = builtins.toJSON {
          home = "${config.services.hermes-agent.stateDir}/.hermes";
          saved = "${config.services.hermes-agent.stateDir}/edits";
          files = lib.mapAttrs (_: source: lib.removePrefix "./" (lib.path.removePrefix ../.. source)) (
            lib.filterAttrs (_: builtins.isPath) config.services.hermes-agent.hermesHomeFiles
          );
        };
      };

      services.hermes-agent.mcpServers.lugh-monitor = {
        command = lib.getExe monitor;
        args = [
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
          "--revision-file"
          "/etc/lugh-monitor/revision"
          "--config-source"
          "/etc/lugh-monitor/config"
          "--managed-files"
          "/etc/lugh-monitor/managed-files.json"
        ];
      };
    };
}
