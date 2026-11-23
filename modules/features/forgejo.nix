# modules/features/forgejo.nix
{
  # The homelab's Git server: Forgejo at git.gatica.one on lugh, a private site (the owner's devices over NetBird).
  # Cosmos lives here; tenjin pushes to it, and Forgejo mirrors every push on to GitHub, where the repo is public.
  # Sign-in is Pocket ID only (no passwords, no sign-ups: the first sign-in makes the account, and the cosmos group
  # makes it an admin). Git goes over SSH as git@git.gatica.one through lugh's own sshd.
  #
  # CI is Forgejo Actions with one runner on lugh that runs jobs straight on the host (label `native`), so its builds
  # use lugh's Nix store: everything CI builds lands in the binary cache through lugh's Attic watcher, with no token
  # in CI. The workflows are in the repo (.forgejo/workflows).
  #
  # The runner registers with a secret shared ahead of time: 16 hex characters that name it (runnerId, here) and 24
  # that are secret (forgejo-runner-secret). Its UUID is those first 16 characters read as bytes.
  flake.modules.nixos.forgejo =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.forgejo;
      domain = "git.gatica.one";
      port = 3002;
      exe = lib.getExe cfg.package;

      # Pocket ID's OIDC client for Forgejo (made through its API; the secret is forgejo-oidc-secret).
      clientId = "023ba57c-43b8-4848-a0da-4a659a73c6fc";

      runnerId = "4b1c2bf808ca40b2";
      runnerUuid =
        let
          hex = lib.concatMapStrings (
            c: lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString (lib.strings.charToInt c)))
          ) (lib.stringToCharacters runnerId);
          part = start: len: builtins.substring start len hex;
        in
        "${part 0 8}-${part 8 4}-${part 12 4}-${part 16 4}-${part 20 12}";
    in
    {
      sops.secrets = {
        forgejo-oidc-secret.sopsFile = ../../secrets/${config.networking.hostName}.yaml;
        forgejo-runner-secret.sopsFile = ../../secrets/${config.networking.hostName}.yaml;
        # The ci account's ntfy token (publish to homelab only), for the weekly update's report.
        ci-ntfy-token.sopsFile = ../../secrets/${config.networking.hostName}.yaml;
        # A GitHub token with no permissions, only so the weekly update's `nix flake update` isn't held to GitHub's
        # 60 requests an hour for unauthenticated clients (shared by the whole house's address).
        github-token.sopsFile = ../../secrets/${config.networking.hostName}.yaml;
      };
      # The runner's whole 40-character secret, which is also its token.
      sops.templates.forgejo-runner-token = {
        content = "${runnerId}${config.sops.placeholder.forgejo-runner-secret}";
      };

      services.forgejo = {
        enable = true;
        # So clones read git@git.gatica.one:…, as on GitHub.
        user = "git";
        group = "git";
        database.type = "sqlite3";
        settings = {
          DEFAULT.APP_NAME = "Cosmos";
          server = {
            DOMAIN = domain;
            ROOT_URL = "https://${domain}/";
            HTTP_ADDR = "127.0.0.1";
            HTTP_PORT = port;
            SSH_DOMAIN = domain;
            LANDING_PAGE = "explore";
          };
          service = {
            # Accounts come only from Pocket ID, made on first sign-in; there's no password form at all.
            DISABLE_REGISTRATION = false;
            ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
            SHOW_REGISTRATION_BUTTON = false;
            ENABLE_INTERNAL_SIGNIN = false;
            REQUIRE_SIGNIN_VIEW = true;
            ENABLE_NOTIFY_MAIL = false;
          };
          oauth2_client = {
            ENABLE_AUTO_REGISTRATION = true;
            USERNAME = "preferred_username";
            ACCOUNT_LINKING = "auto";
            UPDATE_AVATAR = false;
          };
          openid = {
            ENABLE_OPENID_SIGNIN = false;
            ENABLE_OPENID_SIGNUP = false;
          };
          repository = {
            DEFAULT_BRANCH = "main";
            # `git push` to a new name makes the repository.
            ENABLE_PUSH_CREATE_USER = true;
            DEFAULT_PUSH_CREATE_PRIVATE = true;
          };
          actions = {
            ENABLED = true;
            # Where `uses: actions/checkout@v4` and the like come from.
            DEFAULT_ACTIONS_URL = "https://data.forgejo.org";
          };
          session.COOKIE_SECURE = true;
          mailer.ENABLED = false;
          other.SHOW_FOOTER_VERSION = false;
          log.LEVEL = "Warn";
        };
      };

      users.users.git = {
        home = cfg.stateDir;
        useDefaultShell = true;
        group = "git";
        isSystemUser = true;
      };
      users.groups.git = { };

      # What can't go in app.ini: Pocket ID as the sign-in source, and the runner's registration. Both are made or
      # updated in place on every start, so changing them here is enough.
      systemd.services.forgejo-setup = {
        description = "Set up Forgejo's sign-in source and runner";
        after = [ "forgejo.service" ];
        requires = [ "forgejo.service" ];
        wantedBy = [ "forgejo.service" ];
        partOf = [ "forgejo.service" ];
        environment = {
          inherit (config.systemd.services.forgejo.environment)
            USER
            HOME
            FORGEJO_WORK_DIR
            FORGEJO_CUSTOM
            ;
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = cfg.stateDir;
          LoadCredential = [
            "oidc:${config.sops.secrets.forgejo-oidc-secret.path}"
            "runner:${config.sops.templates.forgejo-runner-token.path}"
          ];
        };
        script = ''
          set -euo pipefail
          oauth=(
            --name pocket-id
            --provider openidConnect
            --key ${clientId}
            --secret "$(< "$CREDENTIALS_DIRECTORY/oidc")"
            --auto-discover-url https://id.gatica.one/.well-known/openid-configuration
            --scopes openid --scopes email --scopes profile --scopes groups
            --group-claim-name groups
            --admin-group cosmos
            --required-claim-name groups
            --required-claim-value cosmos
            --skip-local-2fa
          )
          id=$(${exe} admin auth list | ${pkgs.gawk}/bin/awk '$2 == "pocket-id" { print $1 }')
          if [ -n "$id" ]; then
            ${exe} admin auth update-oauth --id "$id" "''${oauth[@]}"
          else
            ${exe} admin auth add-oauth "''${oauth[@]}"
          fi

          ${exe} forgejo-cli actions register --name lugh --labels native --secret "$(< "$CREDENTIALS_DIRECTORY/runner")"
        '';
      };

      services.forgejo-runner.instances.lugh = {
        enable = true;
        settings = {
          runner = {
            labels = [ "native:host" ];
            capacity = 1;
            # A nixpkgs bump can mean long local builds (nabu's CUDA llama.cpp), and the weekly update builds twice.
            timeout = "10h";
          };
          server.connections.lugh = {
            url = "https://${domain}/";
            uuid = runnerUuid;
          };
        };
        secrets.server.connections.lugh.token_url = config.sops.templates.forgejo-runner-token.path;
        # What jobs find on PATH: Nix (through lugh's daemon), Git, and Node for actions like checkout.
        hostPackages = with pkgs; [
          bash
          coreutils
          curl
          findutils
          gawk
          gitMinimal
          gnugrep
          gnused
          jq
          nix
          nodejs
          openssh
          xz
        ];
      };
      systemd.services."forgejo-runner-lugh" = {
        after = [ "forgejo-setup.service" ];
        wants = [ "forgejo-setup.service" ];
        # Jobs run as the runner, so they can read these (/run/credentials/forgejo-runner-lugh.service/…): the weekly
        # update reports through ntfy with one and asks GitHub for new revisions with the other.
        serviceConfig.LoadCredential = [
          "ntfy-token:${config.sops.secrets.ci-ntfy-token.path}"
          "github-token:${config.sops.secrets.github-token.path}"
        ];
      };

      # For the homelab map (modules/topology.nix).
      topology.self.services.forgejo = {
        name = "Forgejo";
        info = domain;
        details.role.text = "Git server for Cosmos (mirrored to GitHub) and its CI.";
      };

      web.sites.git = {
        inherit port;
        healthPath = "/api/healthz";
        homepage = {
          name = "Forgejo";
          group = "Apps";
          icon = "forgejo.png";
          description = "Cosmos and its CI";
        };
        extraConfig = ''
          client_max_body_size 512M;
        '';
      };

      monitor.units = [
        "forgejo"
        "forgejo-runner-lugh"
      ];
    };
}
