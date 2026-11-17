# modules/features/monitor.nix
let
  # Hermes reaches other hosts' monitors over SSH with this key, whose private half is the monitor-ssh-key secret. On
  # those hosts it can only start the monitor.
  hermesKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJCiu8vis0u/3Lp9tYSIbVs6JH6YZPE5TjQnojjrfvRY hermes-monitor";

  # The hosts whose monitors Hermes reaches over SSH, with their host keys.
  remotes = {
    kobold = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFsW8D98Mo2cYCc5ijPszxHPy0qBBnpV4bD/Gxb+ki/U";
  };
in
{
  # Read-only health checks and config lookups for a host, as an MCP server for Hermes. What the host should be running
  # comes from the monitor options its modules fill in (modules/base/monitor.nix).
  flake.modules.nixos.monitor =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      monitor = pkgs.rustPlatform.buildRustPackage {
        pname = "host-monitor";
        version = "0.1.0";
        src = ./monitor;
        cargoLock.lockFile = ./monitor/Cargo.lock;
        meta.mainProgram = "host-monitor";
      };

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
      # Only the host Hermes runs on has it.
      hermesOn = config.services.hermes-agent.enable or false;
      hermes = config.services.hermes-agent;

      # What this host should be running, from the modules that set it up, for the monitor to compare with what is.
      manifest = {
        inherit (m) units ports;
        cards = lib.mapAttrs (short: card: {
          inherit (card) name note;
          pci_id = card.pciId;
          models = lib.attrNames (lib.filterAttrs (_: c: c == short) m.models);
        }) m.cards;
        always_loaded = config.services.llama-swap.settings.hooks.on_startup.preload or [ ];
        check_devices = m.checkDevices;
        # Every subvolume shares the btrfs pool on /, and /boot fills up with old generations.
        disks = [
          "/"
          "/boot"
        ];
      }
      // lib.optionalAttrs hermesOn {
        mcp_servers = lib.mapAttrs (_: s: [ s.command ] ++ s.args or [ ]) (
          lib.filterAttrs (_: s: s.enabled or true) hermes.mcpServers
        );
        # Files the config manages in Hermes' home that come from the repo, so Hermes' edits to them can be found.
        managed_files = {
          home = "${hermes.stateDir}/.hermes";
          saved = "${hermes.stateDir}/edits";
          files = lib.mapAttrs (_: source: lib.removePrefix "./" (lib.path.removePrefix ../.. source)) (
            lib.filterAttrs (_: builtins.isPath) hermes.hermesHomeFiles
          );
        };
      };

      optionalArg =
        flag: value:
        lib.optionals (value != null) [
          flag
          value
        ];
    in
    {
      # The system services Hermes is reached through, where this host has them.
      monitor.units = lib.filter (unit: config.systemd.services ? ${unit}) [
        "sshd"
        "netbird-wt0"
      ];

      # The monitor reads these on every call, so it describes whichever system is active, even though Hermes keeps
      # running across switches. As arguments, they'd also rewrite Hermes' config with every commit.
      environment.etc = {
        "host-monitor/revision".text = lib.defaultTo "unknown" config.system.configurationRevision;
        "host-monitor/config".source = configSource;
        "host-monitor/manifest.json".text = builtins.toJSON manifest;
      };

      monitor.command = [
        (lib.getExe monitor)
        "--host"
        config.networking.hostName
        "--systemctl"
        "${pkgs.systemd}/bin/systemctl"
        "--journalctl"
        "${pkgs.systemd}/bin/journalctl"
        "--revision-file"
        "/etc/host-monitor/revision"
        "--config-source"
        "/etc/host-monitor/config"
        "--manifest"
        "/etc/host-monitor/manifest.json"
      ]
      ++ optionalArg "--llama-server" m.llamaServer
      ++ optionalArg "--llama-swap-url" m.llamaSwapUrl
      ++ optionalArg "--memory-socket" m.memorySocket;

      # Hermes, from its own host, logs in as monitor and gets the monitor on stdin and stdout, whatever it asks to run.
      users.users.monitor = lib.mkIf m.allowHermes {
        isSystemUser = true;
        group = "monitor";
        # The log tool reads the journal.
        extraGroups = [ "systemd-journal" ];
        # sshd runs the forced command through the user's shell.
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys = [
          ''restrict,command="${lib.escapeShellArgs m.command}" ${hermesKey}''
        ];
      };
      users.groups.monitor = lib.mkIf m.allowHermes { };
    };

  # On the host Hermes runs on: its own monitor, run directly, and the other hosts', run over SSH.
  flake.modules.nixos.hermes =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      knownHosts = pkgs.writeText "monitor-known-hosts" (
        lib.concatStrings (lib.mapAttrsToList (host: key: "${host}.netbird.cloud ${key}\n") remotes)
      );
    in
    {
      # The monitor's log tool reads the journal.
      users.users.hermes.extraGroups = [ "systemd-journal" ];

      sops.secrets.monitor-ssh-key = {
        owner = "hermes";
        mode = "0400";
      };

      services.hermes-agent.mcpServers = {
        "${config.networking.hostName}-monitor" = {
          command = lib.head config.monitor.command;
          args = lib.tail config.monitor.command;
        };
      }
      // lib.mapAttrs' (
        host: _:
        lib.nameValuePair "${host}-monitor" {
          command = "${pkgs.openssh}/bin/ssh";
          args = [
            "-i"
            config.sops.secrets.monitor-ssh-key.path
            "-o"
            "BatchMode=yes"
            "-o"
            "IdentitiesOnly=yes"
            "-o"
            "StrictHostKeyChecking=yes"
            "-o"
            "UserKnownHostsFile=${knownHosts}"
            "monitor@${host}.netbird.cloud"
          ];
        }
      ) remotes;
    };
}
