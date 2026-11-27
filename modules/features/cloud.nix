# modules/features/cloud.nix
{
  # Nextcloud at cloud.gatica.one, over NetBird only: calendar, to-dos and contacts first (CalDAV and CardDAV, which
  # the Android phone syncs through DAVx⁵), and files. Sign-in is Pocket ID's (client "Nextcloud", cosmos group only)
  # through the user_oidc app, which the login page goes straight to; the local admin stays for break-glass at
  # /login?direct=1. DAVx⁵ signs in with "Login with Nextcloud", which makes itself an app password.
  flake.modules.nixos.cloud =
    {
      config,
      pkgs,
      ...
    }:
    let
      cfg = config.services.nextcloud;
      clientId = "4bac9932-2431-4bc7-b50d-0cc64adaa872";
    in
    {
      sops.secrets = {
        nextcloud-admin-pass.sopsFile = ../../secrets/${config.networking.hostName}.yaml;
        nextcloud-oidc-secret = {
          sopsFile = ../../secrets/${config.networking.hostName}.yaml;
          restartUnits = [ "nextcloud-oidc.service" ];
        };
      };

      services.nextcloud = {
        enable = true;
        package = pkgs.nextcloud35;
        hostName = "cloud.gatica.one";
        https = true;
        database.createLocally = true;
        configureRedis = true;
        maxUploadSize = "16G";
        config.dbtype = "pgsql";
        # From nixpkgs, pinned with the system; Nextcloud's app store isn't used.
        extraApps = {
          inherit (cfg.package.packages.apps)
            calendar
            contacts
            tasks
            user_oidc
            ;
        };
        extraAppsEnable = true;
        appstoreEnable = false;
        settings = {
          overwriteprotocol = "https";
          # Background jobs that can wait run in the small hours (UTC).
          maintenance_window_start = 10;
        };
        phpOptions."opcache.interned_strings_buffer" = "16";
      };

      # After each setup run: the break-glass admin (this nixpkgs no longer makes one), Pocket ID as the sign-in (the
      # Pocket ID username becomes the Nextcloud one), the login page sent straight to it, and the owner's account
      # made an admin once it exists. As the nextcloud user, which nextcloud-occ expects.
      systemd.services.nextcloud-oidc = {
        description = "Sign in to Nextcloud with Pocket ID";
        after = [
          "nextcloud-setup.service"
          "pocket-id.service"
        ];
        requires = [ "nextcloud-setup.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [ cfg.occ ];
        serviceConfig = {
          Type = "oneshot";
          User = "nextcloud";
          LoadCredential = [
            "admin-pass:${config.sops.secrets.nextcloud-admin-pass.path}"
            "oidc-secret:${config.sops.secrets.nextcloud-oidc-secret.path}"
          ];
        };
        script = ''
          if ! nextcloud-occ user:info admin > /dev/null 2>&1; then
            OC_PASS="$(cat "$CREDENTIALS_DIRECTORY/admin-pass")" nextcloud-occ user:add --password-from-env --group admin admin
          fi
          nextcloud-occ user_oidc:provider "Pocket ID" \
            --clientid=${clientId} \
            --clientsecret="$(cat "$CREDENTIALS_DIRECTORY/oidc-secret")" \
            --discoveryuri=https://id.gatica.one/.well-known/openid-configuration \
            --unique-uid=0 \
            --mapping-uid=preferred_username
          nextcloud-occ config:app:set user_oidc allow_multiple_user_backends --value=0
          if nextcloud-occ user:info twins > /dev/null 2>&1; then
            nextcloud-occ group:adduser admin twins
          fi
        '';
      };

      topology.self.services.nextcloud = {
        name = "Nextcloud";
        info = "cloud.gatica.one";
        details.role.text = "Calendar, to-dos, contacts and files, synced to the phone.";
      };

      web.sites.cloud = {
        selfServed = true;
        healthPath = "/status.php";
        homepage = {
          name = "Nextcloud";
          group = "Apps";
          icon = "nextcloud.png";
          description = "Calendar, contacts, files";
        };
      };

      monitor.units = [
        "phpfpm-nextcloud"
        "redis-nextcloud"
      ];
    };
}
