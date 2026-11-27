# modules/features/minecraft.nix
{ inputs, ... }:
{
  # A Minecraft server on lugh: All the Mods 10 Aeronautics (NeoForge), at mc.gatica.one:25565 over NetBird only. Family
  # devices join with the players setup key (NetBird group players, policy CosmosPlayers); no whitelist, since nobody
  # else can reach it. Online mode stays on, so every player is a real Minecraft account.
  #
  # The pack's server files can't be downloaded without a CurseForge login, so each release's zip is added to lugh's
  # store by hand (nix-store --add-fixed sha256 ATM10AERO-<version>-server.zip, with a GC root next to it), and the
  # matching NeoForge build comes from nix-minecraft. Updating the pack: new zip, new name and hash below, the NeoForge
  # version from its startserver.sh, switch. The world stays in the data directory.
  #
  # Console: `mc-console` (the server's own console, in tmux; Ctrl+b then d leaves it running), or `mc <command>` /
  # plain `mc` for RCON (localhost only), as twins (group minecraft) or root.
  # Nightly at 05:00: players get a warning, the server stops, the whole server directory is archived to
  # /games/minecraft-backups (seven kept), and it starts again.
  flake.modules.nixos.minecraft =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      name = "atm10";
      unit = "minecraft-server-${name}";
      port = 25565;
      rconPort = 25575;
      dataDir = "/games/minecraft";
      backups = "/games/minecraft-backups";
      # node_exporter's textfile collector reads these.
      metrics = "/var/lib/minecraft-metrics";
      socket = "/run/minecraft/${name}.sock";

      pack = pkgs.requireFile {
        name = "ATM10AERO-0.8.0-server.zip";
        sha256 = "85e7e3dbdc264a56344ccb34f726a16031c54897c1fb00c3507459463458bcf8";
        message = ''
          The All the Mods 10 Aeronautics server files come from CurseForge (Files tab, "Server Files"). Add the zip to
          this machine's store: nix-store --add-fixed sha256 ATM10AERO-0.8.0-server.zip
        '';
      };
      packDir = pkgs.runCommand "atm10-aero-0.8.0" { nativeBuildInputs = [ pkgs.unzip ]; } ''
        mkdir "$out" && cd "$out"
        unzip -q ${pack}
        # The pack's own launcher installs NeoForge at run time; nix-minecraft's package replaces it.
        rm -f startserver.sh startserver.bat
      '';

      # Pre-generates the world before anyone plays: `mc "chunky radius 3000" "chunky start"`.
      chunky = pkgs.fetchurl {
        url = "https://cdn.modrinth.com/data/fALzjamp/versions/LuFhm4eU/Chunky-NeoForge-1.4.23.jar";
        sha512 = "2db769dd723f243a21e1881e7c9f825e9c193da6f2bed454b70cb6fa9e51c57f63fdcf017c0657bbd26f7bba30815413e27c74d3c7be0783390a96ee9baa4bf7";
      };
      mods = pkgs.runCommand "atm10-mods" { } ''
        mkdir "$out"
        ln -s ${packDir}/mods/* "$out"/
        # Crash Assistant shows a crash window on the player's desktop; on this server its inner mod isn't loaded and
        # its mixin config can't be found, which stops the server at start ("crash_assistant.mixins.json was invalid").
        rm "$out"/CrashAssistant-*.jar
        ln -s ${chunky} "$out"/Chunky-NeoForge-1.4.23.jar
      '';

      # RCON from lugh itself; the password comes from the same sops file the server reads.
      rcon = pkgs.writeShellApplication {
        name = "mc";
        runtimeInputs = [ pkgs.mcrcon ];
        text = ''
          # shellcheck disable=SC1091
          . ${config.sops.secrets.minecraft-env.path}
          export MCRCON_HOST=127.0.0.1 MCRCON_PORT=${toString rconPort} MCRCON_PASS="$RCON_PASSWORD"
          # No arguments: an interactive RCON prompt.
          if [ $# -eq 0 ]; then exec mcrcon -t; fi
          exec mcrcon "$@"
        '';
      };
      console = pkgs.writeShellApplication {
        name = "mc-console";
        runtimeInputs = [ pkgs.tmux ];
        text = ''
          echo "Server console: type commands without a slash. Ctrl+b then d leaves it running."
          exec tmux -S ${socket} attach
        '';
      };

      # Writes a metrics file in one step, so the exporter never reads half of one.
      publish = ''
        publish() { # name, contents
          printf '%s\n' "$2" > "${metrics}/.$1.tmp"
          mv "${metrics}/.$1.tmp" "${metrics}/$1.prom"
        }
      '';

      # Every minute: up, TPS and tick time (NeoForge's own measure), players, and the Java process's memory.
      collect = pkgs.writeShellApplication {
        name = "minecraft-metrics";
        runtimeInputs = [
          rcon
          pkgs.procps
          pkgs.gnugrep
          pkgs.gnused
          pkgs.coreutils
        ];
        text = ''
          ${publish}
          up=0 tps=0 mspt=0 online=0 rss=0
          if tpsOut=$(mc -c "neoforge tps" 2>/dev/null) && listOut=$(mc -c "list" 2>/dev/null); then
            up=1
            overall=$(grep -i "overall" <<< "$tpsOut" || true)
            tps=$(grep -oiE "([0-9.]+) TPS|TPS: ?[0-9.]+" <<< "$overall" | grep -oE "[0-9.]+" | head -1 || true)
            mspt=$(grep -oiE "[0-9.]+ ?ms" <<< "$overall" | grep -oE "[0-9.]+" | head -1 || true)
            online=$(grep -oE "[0-9]+" <<< "$listOut" | head -1 || true)
          fi
          if pid=$(pgrep -u minecraft -o java); then
            rss=$(( $(grep VmRSS "/proc/$pid/status" | grep -oE "[0-9]+") * 1024 ))
          fi
          publish minecraft "# HELP minecraft_up Whether the server answers RCON.
          minecraft_up{server=\"${name}\"} $up
          minecraft_tps{server=\"${name}\"} ''${tps:-0}
          minecraft_tick_milliseconds{server=\"${name}\"} ''${mspt:-0}
          minecraft_players_online{server=\"${name}\"} ''${online:-0}
          minecraft_memory_rss_bytes{server=\"${name}\"} $rss
          minecraft_metrics_timestamp_seconds{server=\"${name}\"} $(date +%s)"
        '';
      };

      nightly = pkgs.writeShellApplication {
        name = "minecraft-nightly";
        runtimeInputs = [
          rcon
          pkgs.systemd
          pkgs.gnutar
          pkgs.zstd
          pkgs.findutils
          pkgs.coreutils
        ];
        text = ''
          ${publish}
          say() { mc "say $1" > /dev/null 2>&1 || true; }
          if systemctl is-active --quiet ${unit}; then
            say "Nightly restart and backup in 5 minutes."
            sleep 240
            say "Nightly restart and backup in 1 minute. Find somewhere safe!"
            sleep 60
            # Started again however the backup goes.
            trap 'systemctl start ${unit}' EXIT
            systemctl stop ${unit}
          fi
          archive="${backups}/${name}-$(date +%F).tar.zst"
          tar -C ${dataDir} -I "zstd -T0 -3" --exclude="${name}/logs" --exclude="${name}/crash-reports" \
            -cf "$archive.part" ${name}
          mv "$archive.part" "$archive"
          find ${backups} -name "${name}-*.tar.zst" -mtime +6 -delete
          publish minecraft-backup "minecraft_backup_last_success_timestamp_seconds{server=\"${name}\"} $(date +%s)
          minecraft_backup_size_bytes{server=\"${name}\"} $(stat -c %s "$archive")"
        '';
      };

      rule = alert: expr: for: summary: {
        inherit alert expr for;
        labels.severity = "warning";
        annotations.summary = summary;
      };
      rules = pkgs.writeText "minecraft-rules.yml" (
        builtins.toJSON {
          groups = [
            {
              name = "minecraft";
              rules = [
                # Longer than the nightly restart takes.
                (rule "MinecraftDown" "minecraft_up == 0" "10m" "The Minecraft server (ATM10) isn't answering")
                (rule "MinecraftLagging" "avg_over_time(minecraft_tps[5m]) < 15 and minecraft_up == 1" "10m"
                  "The Minecraft server is lagging: {{ $value | printf \"%.1f\" }} TPS (20 is full speed)"
                )
                # 15 GB of heap plus Java's own memory (about 18.5 GB idle with the whole pack loaded); past this, something is leaking.
                (rule "MinecraftMemoryHigh" "minecraft_memory_rss_bytes > 22 * 1024^3" "15m"
                  "The Minecraft server is using {{ $value | humanize1024 }}B of memory"
                )
                (rule "MinecraftBackupMissing"
                  "time() - minecraft_backup_last_success_timestamp_seconds > 26 * 3600"
                  "30m"
                  "The Minecraft world hasn't been backed up in over a day"
                )
                (rule "MinecraftMetricsStale" "time() - minecraft_metrics_timestamp_seconds > 600" "10m"
                  "The Minecraft metrics haven't updated in 10 minutes"
                )
              ];
            }
          ];
        }
      );
    in
    {
      imports = [ inputs.nix-minecraft.nixosModules.minecraft-servers ];
      nixpkgs.overlays = [ inputs.nix-minecraft.overlay ];

      sops.secrets.minecraft-env = {
        sopsFile = ../../secrets/${config.networking.hostName}.yaml;
        group = "minecraft";
        mode = "0440";
        restartUnits = [ "${unit}.service" ];
      };

      services.minecraft-servers = {
        enable = true;
        # Mojang's EULA (https://aka.ms/MinecraftEULA), accepted by the owner.
        eula = true;
        inherit dataDir;
        environmentFile = config.sops.secrets.minecraft-env.path;

        servers.${name} = {
          enable = true;
          # Java 21, which the pack is built and tested for (nix-minecraft would pick the newest Minecraft accepts).
          package = pkgs.neoforgeServers.neoforge-1_21_1-21_1_250.override {
            jre_headless = pkgs.jdk21_headless;
          };
          # 15 GB, fixed, with generational ZGC: pauses well under a millisecond whatever the heap size, for a little
          # more CPU and memory. From Aikar's set, the flags that aren't about G1: the whole heap claimed at start, no
          # full collections forced by mods, no performance counters written to disk.
          jvmOpts = [
            "-Xms15G"
            "-Xmx15G"
            "-XX:+UseZGC"
            "-XX:+ZGenerational"
            "-XX:+AlwaysPreTouch"
            "-XX:+DisableExplicitGC"
            "-XX:+PerfDisableSharedMem"
          ];

          serverProperties = {
            server-port = port;
            motd = "Cosmos - All the Mods 10: Aeronautics";
            difficulty = "normal";
            gamemode = "survival";
            max-players = 10;
            view-distance = 10;
            simulation-distance = 8;
            pvp = true;
            # Jetpacks, wings and the like would otherwise get players kicked for flying.
            allow-flight = true;
            # FTB Chunks claims protect builds instead.
            spawn-protection = 0;
            white-list = false;
            online-mode = true;
            # Heavy modded ticks (world generation) can pass the default 60 s without the server being stuck.
            max-tick-time = 180000;
            enable-rcon = true;
            "rcon.port" = rconPort;
            "rcon.password" = "@RCON_PASSWORD@";
          };

          operators.TwoStupidTwins = {
            uuid = "02a48572-ebac-4770-9421-c6e748f154e3";
            level = 4;
          };

          # The mods are read-only links into the store; the pack's configs and scripts are copied, since some mods
          # write to theirs (changes made in-game are replaced at the next start).
          symlinks = {
            mods = mods;
            datapacks = "${packDir}/datapacks";
          };
          files = {
            config = "${packDir}/config";
            defaultconfigs = "${packDir}/defaultconfigs";
            kubejs = "${packDir}/kubejs";
          };
        };
      };

      # Console access (tmux socket, server files, the RCON password) for the owner.
      users.users.twins.extraGroups = [ "minecraft" ];
      environment.systemPackages = [
        rcon
        console
      ];

      # Over NetBird only: players and the owner's devices.
      networking.firewall.interfaces."nb-wt0".allowedTCPPorts = [ port ];

      systemd.tmpfiles.settings.minecraft = {
        ${backups}.d = {
          user = "root";
          group = "minecraft";
          mode = "0750";
        };
        ${metrics}.d = {
          user = "minecraft";
          group = "minecraft";
          mode = "0755";
        };
      };

      systemd.services.minecraft-metrics = {
        description = "Minecraft server metrics for Prometheus";
        after = [ "${unit}.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "minecraft";
          Group = "minecraft";
          ExecStart = lib.getExe collect;
        };
      };
      systemd.timers.minecraft-metrics = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2m";
          OnUnitActiveSec = "1m";
        };
      };

      systemd.services.minecraft-nightly = {
        description = "Restart the Minecraft server and back up its world";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe nightly;
        };
      };
      systemd.timers.minecraft-nightly = {
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = "*-*-* 05:00:00";
      };

      services.prometheus.exporters.node.extraFlags = [ "--collector.textfile.directory=${metrics}" ];
      services.prometheus.ruleFiles = [ rules ];

      topology.self.services.minecraft = {
        name = "Minecraft";
        info = "mc.gatica.one:${toString port}";
        details.role.text = "All the Mods 10 Aeronautics, for family over NetBird.";
      };

      monitor = {
        units = [ unit ];
        ports.minecraft = port;
      };
    };
}
