{ ... }:
{
  flake.nixosModules.greetd = { config, pkgs, ... }: {
    services.greetd = {
      enable = true;
      settings.default_session = {
        user = "greeter";
	command = ''
	  ${pkgs.tuigreet}/bin/tuigreet \
	  --time \
	  --remember \
	  --cmd ${config.programs.niri.package}/bin/niri-session
	'';
      };
    };
  };
}
