# modules/features/hermes-wiki.nix
{
  # Two Obsidian vaults kept on lugh through Obsidian Sync:
  # - the research wiki Hermes maintains (shareable: research subagents may search it);
  # - the owner's personal notes, which Hermes may read and edit but must never pass to subagents.
  flake.modules.nixos.hermes =
    { lib, pkgs, ... }:
    let
      home = "/var/lib/hermes";
      wiki = "${home}/wiki";
      notes = "${home}/notes";
      ob = lib.getExe pkgs.obsidian-headless;

      # One continuous sync per vault. `ob` keeps each vault's sync settings apart, by its local
      # path, under the one account login.
      sync = description: path: {
        inherit description;
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        # Waits for ob login, which saves the account's sync settings here.
        unitConfig.ConditionDirectoryNotEmpty = "${home}/.config/obsidian-headless/sync";

        serviceConfig = {
          User = "hermes";
          Group = "hermes";
          Environment = "HOME=${home}";
          ExecStart = "${ob} sync --continuous --path ${path}";
          Restart = "always";
          RestartSec = 30;
          UMask = "0007";

          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ home ];
        };
      };
    in
    {
      # For the one-time setup, as the hermes user:
      #   sudo -u hermes -H ob login
      #   sudo -u hermes -H ob sync-setup --vault Wiki --path /var/lib/hermes/wiki --device-name lugh
      #   sudo -u hermes -H ob sync-setup --vault Notes --path /var/lib/hermes/notes --device-name lugh
      environment.systemPackages = [ pkgs.obsidian-headless ];

      monitor.units = [
        "obsidian-sync"
        "obsidian-sync-notes"
      ];

      # Setgid, so files Hermes and the syncs create stay in the hermes group, which twins is in.
      systemd.tmpfiles.rules = [
        "d ${wiki} 2770 hermes hermes -"
        "d ${notes} 2770 hermes hermes -"
      ];

      services.hermes-agent = {
        # Teaches Hermes the wiki's format and when to file research into it.
        hermesHomeFiles."skills/research/llm-wiki/SKILL.md" = ./hermes-wiki/SKILL.md;
        # Hermes' bundled Obsidian skill looks for the vault here.
        environment.OBSIDIAN_VAULT_PATH = wiki;
        # wiki_search and wiki_related come from the memory plugin in hermes-memory.nix.
      };

      systemd.services.obsidian-sync = sync "Obsidian Sync for Hermes' wiki" wiki;
      systemd.services.obsidian-sync-notes = lib.recursiveUpdate (sync "Obsidian Sync for the owner's personal notes" notes) {
        # Skipped rather than failed until `ob sync-setup` links the folder to the remote vault
        # (sync-status exits 3 for a path with no sync settings).
        serviceConfig.ExecCondition = "${ob} sync-status --path ${notes}";
      };
    };
}
