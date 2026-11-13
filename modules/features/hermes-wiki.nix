# modules/features/hermes-wiki.nix
{
  # A research wiki Hermes maintains, synced to the owner's Obsidian through Obsidian Sync.
  flake.modules.nixos.hermes =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      home = "/var/lib/hermes";
      wiki = "${home}/wiki";
      ob = lib.getExe pkgs.obsidian-headless;
      searchPython = pkgs.python3.withPackages (p: [
        p.mcp
        p.numpy
        p.pyyaml
      ]);
    in
    {
      # For the one-time setup, as the hermes user:
      #   sudo -u hermes -H ob login
      #   sudo -u hermes -H ob sync-setup --vault Wiki --path /var/lib/hermes/wiki --device-name lugh
      environment.systemPackages = [ pkgs.obsidian-headless ];

      # Setgid, so files Hermes and the sync create stay in the hermes group, which twins is in.
      systemd.tmpfiles.rules = [ "d ${wiki} 2770 hermes hermes -" ];

      services.hermes-agent = {
        # Teaches Hermes the wiki's format and when to file research into it.
        hermesHomeFiles."skills/research/llm-wiki/SKILL.md" = ./hermes-wiki/SKILL.md;
        # Hermes' bundled Obsidian skill looks for the vault here.
        environment.OBSIDIAN_VAULT_PATH = wiki;

        # Finds pages by meaning, with the local embedding model and reranker. Its index lives outside
        # the wiki, so it never syncs to Obsidian.
        mcpServers.wiki-search = {
          command = "${searchPython}/bin/python3";
          args = [
            "-I"
            "${./wiki-search.py}"
            "--wiki"
            wiki
            "--index"
            "${home}/.cache/wiki-search/index.sqlite"
            "--llama-swap-url"
            "http://127.0.0.1:${toString config.services.llama-swap.port}"
          ];
        };
      };

      systemd.services.obsidian-sync = {
        description = "Obsidian Sync for Hermes' wiki";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        # Waits for ob sync-setup, which saves the vault's sync settings here.
        unitConfig.ConditionDirectoryNotEmpty = "${home}/.config/obsidian-headless/sync";

        serviceConfig = {
          User = "hermes";
          Group = "hermes";
          Environment = "HOME=${home}";
          ExecStart = "${ob} sync --continuous --path ${wiki}";
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
    };
}
