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
      llama-cpp =
        (inputs.llama-cpp.packages.${pkgs.stdenv.hostPlatform.system}.vulkan.override { useWebUi = false; })
        .overrideAttrs
          { webui = null; };

      # The config this system was built from, for the config tools. Secrets stay out, and so do the wallpapers.
      configSource = lib.fileset.toSource {
        root = ../..;
        fileset =
          lib.fileset.intersection
            (lib.fileset.unions [
              ../../flake.nix
              ../../flake.lock
              ../../modules
            ])
            (
              lib.fileset.fileFilter (
                file:
                !lib.any file.hasExt [
                  "png"
                  "jpg"
                  "jpeg"
                  "webp"
                  "gif"
                ]
              ) ../..
            );
      };

      m = config.monitor;
      hermes = config.services.hermes-agent;

      # What lugh should be running, from the modules that set it up, for the monitor to compare with what is.
      manifest = {
        inherit (m) units ports;
        cards = lib.mapAttrs (short: card: {
          inherit (card) name note;
          pci_id = card.pciId;
          models = lib.attrNames (lib.filterAttrs (_: c: c == short) m.models);
        }) m.cards;
        always_loaded = config.services.llama-swap.settings.hooks.on_startup.preload;
        check_devices = m.checkDevices;
        mcp_servers = lib.mapAttrs (_: s: s.command) (
          lib.filterAttrs (_: s: s.enabled or true) hermes.mcpServers
        );
        # Every subvolume shares the btrfs pool on /, and /boot fills up with old generations.
        disks = [
          "/"
          "/boot"
        ];
        # Files the config manages in Hermes' home that come from the repo, so Hermes' edits to them can be found.
        managed_files = {
          home = "${hermes.stateDir}/.hermes";
          saved = "${hermes.stateDir}/edits";
          files = lib.mapAttrs (_: source: lib.removePrefix "./" (lib.path.removePrefix ../.. source)) (
            lib.filterAttrs (_: builtins.isPath) hermes.hermesHomeFiles
          );
        };
      };
    in
    {
      # The monitor's log tool reads the journal.
      users.users.hermes.extraGroups = [ "systemd-journal" ];

      # The system services Hermes is reached through, where this host has them.
      monitor.units = lib.filter (unit: config.systemd.services ? ${unit}) [
        "sshd"
        "netbird-wt0"
      ];

      # The monitor reads these on every call, so it describes whichever system is active, even though Hermes keeps
      # running across switches. As arguments, they'd also rewrite Hermes' config with every commit.
      environment.etc = {
        "lugh-monitor/revision".text = lib.defaultTo "unknown" config.system.configurationRevision;
        "lugh-monitor/config".source = configSource;
        "lugh-monitor/manifest.json".text = builtins.toJSON manifest;
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
          hermes.environment.HERMES_MEMORY_SOCKET
          "--revision-file"
          "/etc/lugh-monitor/revision"
          "--config-source"
          "/etc/lugh-monitor/config"
          "--manifest"
          "/etc/lugh-monitor/manifest.json"
        ];
      };
    };
}
