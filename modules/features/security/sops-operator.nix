# Interactive operator editing is separate from unattended host-key decryption.
{
  flake.modules.nixos."sops-operator" =
    { config, pkgs, ... }:
    let
      operatorIdentity = pkgs.callPackage ../../../packages/sops-operator-identity.nix { };
    in
    {
      assertions = [
        {
          assertion = config.programs._1password.enable;
          message = "sops-operator requires the authorized 1Password CLI on the editing workstation.";
        }
      ];
      environment.systemPackages = [ operatorIdentity ];
      environment.variables.SOPS_AGE_KEY_CMD = "${operatorIdentity}/bin/cosmos-sops-identity";
    };
}
