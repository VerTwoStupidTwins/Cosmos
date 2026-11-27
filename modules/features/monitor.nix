# modules/features/monitor.nix
{ config, lib, ... }:
let
  # The desktop bar's key (its private half is in secrets/tenjin.yaml), and the hosts its homelab
  # plate checks, by host key (modules/base/known-hosts.nix). Each of them sets monitor.allowStation.
  stationKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMw0/t1en+PuDl7iQiW/6f0DLorwLSHcLP+WdOtpYIxw station-monitor";
  labHosts = lib.getAttrs [
    "lugh"
    "nabu"
  ] config.cosmos.hostKeys;
in
{
  # Read-only health checks and config lookups for a host, as an MCP server over stdio. What the host should be running
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

      # What this host should be running, from the modules that set it up, for the monitor to compare with what is.
      manifest = {
        inherit (m) units ports;
        # Every subvolume shares the filesystem on /, and /boot fills up with old generations.
        disks = [
          "/"
          "/boot"
        ];
        nvme_health_dir = nvmeHealthDir;
      };

      command = [
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
      ];
    in
    {
      monitor.command = command;

      # The system services the host is reached through, where it has them.
      monitor.units = lib.filter (unit: config.systemd.services ? ${unit}) [
        "sshd"
        "netbird-wt0"
      ];

      # The monitor reads these on every call, so it describes whichever system is active, and its command line, in
      # the monitor user's SSH key, stays the same from commit to commit.
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

      # The desktop bar logs in as monitor and gets the monitor on stdin and stdout, whatever it asks to run.
      users.users.monitor = lib.mkIf m.allowStation {
        isSystemUser = true;
        group = "monitor";
        # The log tool reads the journal.
        extraGroups = [ "systemd-journal" ];
        # sshd runs the forced command through the user's shell.
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys = [
          ''restrict,command="${lib.escapeShellArgs config.monitor.command}" ${stationKey}''
        ];
      };
      users.groups.monitor = lib.mkIf m.allowStation { };
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
}
