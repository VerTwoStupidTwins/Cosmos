# modules/features/monitor.nix
let
  # Hermes reaches other hosts' monitors over SSH with this key, whose private half is the monitor-ssh-key secret. On
  # those hosts it can only start the monitor.
  hermesKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJCiu8vis0u/3Lp9tYSIbVs6JH6YZPE5TjQnojjrfvRY hermes-monitor";

  # The hosts whose monitors Hermes reaches over SSH, with their host keys.
  remotes = {
    kobold = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFsW8D98Mo2cYCc5ijPszxHPy0qBBnpV4bD/Gxb+ki/U";
  };

  # The desktop bar's key (its private half is in secrets/tenjin.yaml), and the hosts its homelab
  # plate checks, by host key. Each of them sets monitor.allowStation.
  stationKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMw0/t1en+PuDl7iQiW/6f0DLorwLSHcLP+WdOtpYIxw station-monitor";
  labHosts = {
    lugh = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF3DM9wpr41MlWUe1+C05lht9vg1a9h1XNqFGBbw5oAU";
    inherit (remotes) kobold;
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

      # Reading NVMe health needs root, so this saves it where the monitor, which runs unprivileged, can read it.
      nvmeHealthDir = "/run/host-monitor/nvme";
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
        # Every subvolume shares the filesystem on /, and /boot fills up with old generations.
        disks = [
          "/"
          "/boot"
        ];
        nvme_health_dir = nvmeHealthDir;
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

      # The monitor without the memory check, for the desktop bar: the memory service's socket is
      # Hermes' alone, so as the monitor user that check could only fail.
      stationCommand = [
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
      ++ optionalArg "--llama-swap-url" m.llamaSwapUrl;
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

      systemd.services.host-monitor-nvme = {
        description = "Save NVMe health for the host monitor";
        path = [ pkgs.nvme-cli ];
        serviceConfig = {
          Type = "oneshot";
          RuntimeDirectory = "host-monitor/nvme";
          RuntimeDirectoryPreserve = true;
          RuntimeDirectoryMode = "0755";
        };
        # One file per controller (nvme0, nvme1, …), replaced whole so the monitor never reads half of one.
        script = ''
          for dev in /dev/nvme[0-9]*; do
            [ -c "$dev" ] || continue
            name=$(basename "$dev")
            if nvme smart-log "$dev" -o json > ${nvmeHealthDir}/.$name.tmp; then
              mv ${nvmeHealthDir}/.$name.tmp ${nvmeHealthDir}/$name.json
            else
              rm -f ${nvmeHealthDir}/.$name.tmp
            fi
          done
        '';
      };
      systemd.timers.host-monitor-nvme = {
        wantedBy = [ "timers.target" ];
        # OnActiveSec covers the switch that adds the timer, after boot is long past.
        timerConfig = {
          OnBootSec = "1min";
          OnActiveSec = "1min";
          OnUnitActiveSec = "1h";
        };
      };

      monitor.command = stationCommand ++ optionalArg "--memory-socket" m.memorySocket;

      # Hermes, from its own host, and the desktop bar log in as monitor and get the monitor on stdin and stdout,
      # whatever they ask to run.
      users.users.monitor = lib.mkIf (m.allowHermes || m.allowStation) {
        isSystemUser = true;
        group = "monitor";
        # The log tool reads the journal.
        extraGroups = [ "systemd-journal" ];
        # sshd runs the forced command through the user's shell.
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys =
          map (key: ''restrict,command="${lib.escapeShellArgs m.command}" ${key}'') (
            lib.optional m.allowHermes hermesKey
          )
          ++ lib.optional m.allowStation ''restrict,command="${lib.escapeShellArgs stationCommand}" ${stationKey}'';
      };
      users.groups.monitor = lib.mkIf (m.allowHermes || m.allowStation) { };
    };

  # On a desktop: the bar's homelab plate asks each lab host's monitor for its health report, over SSH
  # with its own key, which those hosts only let run the monitor.
  flake.modules.nixos.monitor-station =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      knownHosts = pkgs.writeText "lab-known-hosts" (
        lib.concatStrings (lib.mapAttrsToList (host: key: "${host}.netbird.cloud ${key}\n") labHosts)
      );
      # An MCP session: initialize, then health_report (id 2). stdin stays open until the answer
      # arrives, since the monitor stops reading when it closes.
      requests = pkgs.writeText "lab-requests" ''
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"station","version":"1"}}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"health_report","arguments":{}}}
      '';
    in
    {
      sops.secrets.station-monitor-key = {
        sopsFile = ../../secrets/tenjin.yaml;
        owner = "twins";
        mode = "0400";
      };

      # One line per host: {"host": …, "report": {…}}, or {"host": …, "error": "…"} when it didn't answer.
      monitor.labCommand = pkgs.writeShellScript "homelab-status" ''
        PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.jq
            pkgs.openssh
          ]
        }
        tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
        check() {
          local host=$1 done=$tmp/$1.done
          { cat ${requests}; while [ ! -e "$done" ]; do sleep 0.3; done; } |
            timeout 30 ssh -i ${config.sops.secrets.station-monitor-key.path} -o BatchMode=yes -o IdentitiesOnly=yes \
              -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${knownHosts} -o ConnectTimeout=6 \
              "monitor@$host.netbird.cloud" 2> "$tmp/$host.err" |
            { grep -m1 '"id":2' > "$tmp/$host.out"; touch "$done"; }
          if [ -s "$tmp/$host.out" ] &&
            jq -c --arg host "$host" '{host: $host, report: (.result.content[0].text | fromjson)}' "$tmp/$host.out" > "$tmp/$host.json" 2>/dev/null; then
            :
          else
            jq -nc --arg host "$host" --arg error "$(grep -v '^Warning' "$tmp/$host.err" | tr -d '\r' | tail -n1)" \
              '{host: $host, error: (if $error == "" then "no answer" else $error end)}' > "$tmp/$host.json"
          fi
        }
        for host in ${lib.concatStringsSep " " (lib.attrNames labHosts)}; do check "$host" & done
        wait
        cat "$tmp"/*.json
      '';
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
