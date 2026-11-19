# modules/features/hermes-notes.nix
{
  # Handwritten notes in the owner's Notes vault (synced to lugh by hermes-wiki.nix) become Markdown:
  # each PNG that Excalidraw exports beside a drawing goes to the main model, which can see, and the
  # transcription is written as a note in the vault's Inbox folder. Runs as hermes, so the notes are
  # Hermes' to index and edit like the rest of the vault.
  flake.modules.nixos.hermes =
    { config, pkgs, ... }:
    let
      notes = "/var/lib/hermes/notes";
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
        ];
        text = builtins.readFile ./hermes-notes/transcribe.sh;
      };
    in
    {
      monitor.units = [ "notes-transcriber" ];

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
