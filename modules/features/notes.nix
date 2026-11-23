# modules/features/notes.nix
{
  # The owner's Obsidian vault on lugh, kept in step with every other device by Obsidian Sync: Obsidian's own headless
  # client (ob) runs as the notes user and syncs /var/lib/notes/vault continuously. The agent works on the notes there
  # through its notes tool (agent-tools/notes, `notes serve`, with the agent in the notes group); edits from either
  # side reach the owner's devices through Sync. The same program's `notes watch` is the transcriber: each handwritten
  # Excalidraw drawing becomes an inbox note, read by nabu's vision model.
  #
  # Signing in and choosing the vault happen once, by the owner, through ob-notes (ob as the notes user):
  #   sudo ob-notes login
  #   sudo ob-notes sync-list-remote
  #   sudo ob-notes sync-setup --vault "<name>" --path /var/lib/notes/vault --device-name lugh
  #   sudo systemctl start obsidian-sync
  # ob keeps its token and the vault's settings (the end-to-end password included) in /var/lib/notes/.config, readable
  # by the notes user only.
  flake.modules.nixos.notes =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.notes;
      home = "/var/lib/notes";
      vault = "${home}/vault";
      configHome = "${home}/.config";
      environment.XDG_CONFIG_HOME = configHome;

      ob-notes = pkgs.writeShellApplication {
        name = "ob-notes";
        runtimeInputs = [ pkgs.util-linux ];
        text = ''
          if [ "$(id -u)" -ne 0 ]; then
            echo "Run it with sudo: it runs ob as the notes user." >&2
            exit 1
          fi
          cd ${home}
          exec setpriv --reuid=notes --regid=notes --init-groups --reset-env \
            env HOME=${home} XDG_CONFIG_HOME=${configHome} ${lib.getExe' pkgs.obsidian-headless "ob"} "$@"
        '';
      };

      # The agent's note tools and the transcriber, one program; its tests run with the build.
      notesTool = pkgs.rustPlatform.buildRustPackage {
        pname = "notes";
        version = "0.1.0";
        src = ./agent-tools/notes;
        cargoLock.lockFile = ./agent-tools/notes/Cargo.lock;
        meta.mainProgram = "notes";
      };

      sandbox = {
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    in
    {
      options.notes = {
        package = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          default = notesTool;
          description = "The notes program: `serve` (the agent's note tools) and `watch` (the transcriber).";
        };
        vault = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = vault;
        };
        models = lib.mkOption {
          type = lib.types.str;
          default = "http://nabu.netbird.cloud:8080/v1";
          description = "The OpenAI-style API with the vision model (nabu's llama-swap).";
        };
      };

      config = {
        users.users.notes = {
          isSystemUser = true;
          group = "notes";
          inherit home;
        };
        users.groups.notes = { };

        # The vault is the group's to write (setgid, so new files stay in it); ob's own settings are the notes user's
        # alone.
        systemd.tmpfiles.settings.notes = {
          ${home}.d = {
            user = "notes";
            group = "notes";
            mode = "0750";
          };
          ${vault}.d = {
            user = "notes";
            group = "notes";
            mode = "2770";
          };
          ${configHome}.d = {
            user = "notes";
            group = "notes";
            mode = "0700";
          };
        };

        environment.systemPackages = [ ob-notes ];

        systemd.services.obsidian-sync = {
          description = "Sync the Obsidian vault (Obsidian Sync)";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          inherit environment;
          # Until the owner has signed in (above), there's nothing to run.
          unitConfig.ConditionPathExists = "${configHome}/obsidian-headless/auth_token";
          serviceConfig = sandbox // {
            User = "notes";
            Group = "notes";
            WorkingDirectory = home;
            ExecStart = "${lib.getExe' pkgs.obsidian-headless "ob"} sync --continuous --path ${vault}";
            # Files it writes stay writable by the group (the agent).
            UMask = "0007";
            Restart = "always";
            RestartSec = 30;
            ReadWritePaths = [ home ];
          };
        };

        # Handwritten notes: each PNG that Excalidraw exports beside a drawing goes to the vision model, and the
        # transcription becomes a note in Inbox (with the drawing embedded, to check it against). It never re-sends an
        # unchanged drawing, and never replaces a transcription the owner has edited (it marks it outdated instead).
        systemd.services.notes-transcriber = {
          description = "Transcribe handwritten notes in the Obsidian vault";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-online.target" ];
          after = [
            "network-online.target"
            "obsidian-sync.service"
          ];
          environment = {
            NOTES = vault;
            STATE = "/var/lib/notes-transcriber";
            API = "${cfg.models}/chat/completions";
            MODEL = "vision";
            PROMPT = "${./agent-tools/notes/transcribe-prompt.txt}";
            REQUEST = "${./agent-tools/notes/transcribe-request.txt}";
          };
          serviceConfig = sandbox // {
            User = "notes";
            Group = "notes";
            ExecStart = "${lib.getExe notesTool} watch";
            # Which PNGs it has transcribed, kept out of the vault.
            StateDirectory = "notes-transcriber";
            UMask = "0007";
            Restart = "always";
            RestartSec = 30;
            ReadWritePaths = [ vault ];
          };
        };

        monitor.units = [
          "obsidian-sync"
          "notes-transcriber"
        ];
      };
    };
}
