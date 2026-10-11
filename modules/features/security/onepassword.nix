{
  flake.modules.nixos.workstation = { lib, ... }: {
    nixpkgs.config.allowUnfreePredicate = pkg:
      builtins.elem (lib.getName pkg) [
        "1password"
	"1password-cli"
	"1password-gui"
      ];
    
    programs._1password.enable = true;

    programs._1password-gui = {
      enable = true;
      polkitPolicyOwners = [ "twins" ];
    };

    programs.ssh = {
      startAgent = false;

      extraConfig = ''
        Host *
	  IdentityAgent ~/.1password/agent.sock
      '';
    };
  };
}
