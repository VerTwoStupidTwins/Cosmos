# modules/features/notes.nix
{
  # The owner's Obsidian vault on lugh, kept in step with every other device by Obsidian Sync: Obsidian's own headless
  # client (ob) runs as the notes user and syncs /var/lib/notes/vault continuously. The agent works on the notes there
  # (it joins the notes group); edits from either side reach the owner's devices through Sync.
  #
  # Signing in and choosing the vault happen once, by the owner, through ob-notes (ob as the notes user):
  #   sudo ob-notes login
  #   sudo ob-notes sync-list-remote
  #   sudo ob-notes sync-setup --vault "<name>" --path /var/lib/notes/vault --device-name lugh
  #   sudo systemctl start obsidian-sync
  # ob keeps its token and the vault's settings (the end-to-end password included) in /var/lib/notes/.config, readable
  # by the notes user only.
  flake.modules.nixos.notes =
    { lib, pkgs, ... }:
    let
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
    in
    {
      users.users.notes = {
        isSystemUser = true;
        group = "notes";
        inherit home;
      };
      users.groups.notes = { };

      # The vault is the group's to write (setgid, so new files stay in it); ob's own settings are the notes user's alone.
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
        serviceConfig = {
          User = "notes";
          Group = "notes";
          WorkingDirectory = home;
          ExecStart = "${lib.getExe' pkgs.obsidian-headless "ob"} sync --continuous --path ${vault}";
          # Files it writes stay writable by the group (the agent).
          UMask = "0007";
          Restart = "always";
          RestartSec = 30;
          ProtectSystem = "strict";
          ReadWritePaths = [ home ];
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
      };

      monitor.units = [ "obsidian-sync" ];
    };
}
