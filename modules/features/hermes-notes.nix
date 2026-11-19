# modules/features/hermes-notes.nix
{
  # Handwritten notes in the owner's Notes vault (synced to lugh by hermes-wiki.nix) become Markdown:
  # each PNG that Excalidraw exports beside a drawing goes to the main model, which can see, and the
  # transcription is written as a note in the vault's Inbox folder. Runs as hermes, so the notes are
  # Hermes' to index and edit like the rest of the vault.
  #
  # The owner reviews the inbox and marks each note `review: accept` or `review: delete`. At
  # midnight Hermes' notes-ingest job deletes the rejected notes and files the accepted ones into the
  # vault with the notes-ingest skill: to-dos into Tasks.md, the rest linked to topics and feelings.
  flake.modules.nixos.hermes =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      notes = "/var/lib/hermes/notes";

      # The one thing that deletes notes: an inbox note with its drawing.
      remove = pkgs.writeShellApplication {
        name = "notes-remove";
        runtimeInputs = with pkgs; [
          coreutils
          gawk
        ];
        text = builtins.readFile ./hermes-notes/remove.sh;
      };

      transcriber = pkgs.writeShellApplication {
        name = "notes-transcriber";
        runtimeInputs = with pkgs; [
          coreutils
          curl
          findutils
          gawk
          gnused
          inotify-tools
          jq
          remove
        ];
        text = builtins.readFile ./hermes-notes/transcribe.sh;
      };

      # Run by Hermes before the nightly job's agent, so it has to live in Hermes' scripts folder.
      nightly = pkgs.replaceVars ./hermes-notes/notes-nightly.sh {
        awk = lib.getExe pkgs.gawk;
        remove = lib.getExe remove;
      };
    in
    {
      monitor.units = [ "notes-transcriber" ];

      services.hermes-agent.hermesHomeFiles = {
        # How to file accepted inbox notes into the vault. The job itself is made once, from a chat
        # with Hermes, since its replies go back to where it was made.
        "skills/note-taking/notes-ingest/SKILL.md" = ./hermes-notes/SKILL.md;
        "scripts/notes-nightly.sh" = nightly;
      };

      systemd.services.notes-transcriber = {
        description = "Transcribe handwritten notes in the Notes vault";
        wantedBy = [ "multi-user.target" ];
        wants = [ "llama-swap.service" ];
        after = [
          "llama-swap.service"
          "obsidian-sync-notes.service"
        ];
        environment = {
          NOTES = notes;
          STATE = "/var/lib/notes-transcriber";
          API = "http://127.0.0.1:${toString config.services.llama-swap.port}/v1/chat/completions";
          MODEL = "main";
          PROMPT = "${./hermes-notes/transcribe-prompt.txt}";
          REQUEST = "${./hermes-notes/transcribe-request.txt}";
        };
        # The vault folder comes from hermes-wiki.nix's tmpfiles rule.
        unitConfig.ConditionPathIsDirectory = notes;

        serviceConfig = {
          User = "hermes";
          Group = "hermes";
          ExecStart = "${transcriber}/bin/notes-transcriber";
          # Which PNGs it has transcribed, kept out of the vault.
          StateDirectory = "notes-transcriber";
          Restart = "always";
          RestartSec = 30;
          UMask = "0007";

          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ notes ];
        };
      };
    };
}
