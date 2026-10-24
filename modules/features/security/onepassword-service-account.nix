{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  flake.modules.nixos."onepassword-service-account" =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      verify = pkgs.callPackage ../../../packages/onepassword-service-account-verify.nix {
        opPackage = pkgs._1password-cli;
      };
    in
    {
      imports = [
        nixos."sops-secrets"

      ];
      cosmos.allowedUnfreePackages = [ "1password-cli" ];
      system.build.onepassword-service-account-verify = verify;
      sops.secrets.onepassword-service-account-token = {
        key = "onepassword_service_account_token";
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "onepassword-service-account-verify.service" ];
      };
      systemd.services.onepassword-service-account-verify = {
        description = "Verify restricted 1Password service-account access";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        environment = {
          OP_CONFIG_DIR = "/run/cosmos-onepassword/op";
          HOME = "/run/cosmos-onepassword";
        };
        serviceConfig = {
          Type = "oneshot";
          DynamicUser = true;
          LoadCredential = [ "token:${config.sops.secrets.onepassword-service-account-token.path}" ];
          ExecStart = lib.escapeShellArgs [
            "${verify}/bin/cosmos-onepassword-verify"
            "%d/token"
            "Cosmos Runtime"
          ];
          RuntimeDirectory = "cosmos-onepassword";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
          TimeoutStartSec = "90s";
          LimitCORE = 0;
          NoNewPrivileges = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictSUIDSGID = true;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
          InaccessiblePaths = [
            "/etc/ssh"
            "/run/secrets"
          ];
        };
      };
    };
  perSystem = { pkgs, ... }: {
    checks.onepassword-service-account = import ../../../tests/onepassword-service-account.nix {
      inherit pkgs;
      odin = config.flake.nixosConfigurations.odin.config;
      thoth = config.flake.nixosConfigurations.thoth.config;
      argus = config.flake.nixosConfigurations.argus.config;
    };
  };
}
