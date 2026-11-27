# modules/features/budget.nix
{
  # Actual Budget at budget.gatica.one, over NetBird only. Actual keeps the budget in the browser and syncs it through
  # this server. Sign-in is Pocket ID's (client "Actual Budget", cosmos group only), enforced, so there's no
  # server password; the first account to sign in becomes the owner.
  flake.modules.nixos.budget =
    { config, ... }:
    let
      port = 5006;
    in
    {
      sops.secrets.actual-oidc-secret = {
        sopsFile = ../../secrets/${config.networking.hostName}.yaml;
        restartUnits = [ "actual.service" ];
      };

      services.actual = {
        enable = true;
        settings = {
          hostname = "127.0.0.1";
          inherit port;
          loginMethod = "openid";
          allowedLoginMethods = [ "openid" ];
        };
      };

      systemd.services.actual = {
        environment = {
          ACTUAL_OPENID_ENFORCE = "true";
          ACTUAL_OPENID_DISCOVERY_URL = "https://id.gatica.one";
          ACTUAL_OPENID_PROVIDER_NAME = "Pocket ID";
          ACTUAL_OPENID_CLIENT_ID = "0a6ff7f1-9557-4953-afb1-9135efeb0d94";
          # From the service's credentials (it runs as a dynamic user, which can't read the sops file itself).
          ACTUAL_OPENID_CLIENT_SECRET_FILE = "%d/oidc-secret";
          ACTUAL_OPENID_SERVER_HOSTNAME = "https://budget.gatica.one";
          # nginx on the same host is the only proxy in front of it.
          ACTUAL_TRUSTED_PROXIES = "127.0.0.1/32";
        };
        serviceConfig.LoadCredential = [ "oidc-secret:${config.sops.secrets.actual-oidc-secret.path}" ];
        # Pocket ID is on this host too; sign-in needs it answering.
        after = [ "pocket-id.service" ];
        wants = [ "pocket-id.service" ];
      };

      topology.self.services.actual = {
        name = "Actual Budget";
        info = "budget.gatica.one";
        details.role.text = "Personal budgeting, synced between devices.";
      };

      web.sites.budget = {
        inherit port;
        healthPath = "/health";
        # Bank files and backups can be imported.
        extraConfig = ''
          client_max_body_size 50M;
        '';
        homepage = {
          name = "Actual Budget";
          group = "Apps";
          icon = "actual-budget.png";
          description = "Budget";
        };
      };

      monitor = {
        units = [ "actual" ];
        ports.actual = port;
      };
    };
}
