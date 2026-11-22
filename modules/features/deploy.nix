# modules/features/deploy.nix
# One command per host for the machine the owner deploys from: rebuild-<host> [switch|boot|test|build] [nh flags…].
# The deploying host switches itself (its heavy builds already go to lugh, as a build client); every other host is built
# on lugh and copied straight to it, so nothing big crosses the laptop's link twice.
{ config, lib, ... }:
let
  builder = "lugh";
  flake = "/Cosmos";
  hosts = builtins.attrNames config.hosts;
in
{
  flake.modules.nixos.deploy =
    { config, ... }:
    let
      self = config.networking.hostName;
      command =
        host:
        if host == self then
          "nh os $verb ${flake} $argv"
        else
          "nh os $verb ${flake} -H ${host} --target-host ${host} --build-host ${builder} $argv";
    in
    {
      home-manager.users.twins.programs.fish.functions = lib.genAttrs' hosts (host: {
        name = "rebuild-${host}";
        value = {
          description = "Rebuild ${host}${lib.optionalString (host != self) " on ${builder}"}: [switch|boot|test|build] [nh flags]";
          body = ''
            set -l verb switch
            if set -q argv[1]; and contains -- $argv[1] switch boot test build
              set verb $argv[1]
              set -e argv[1]
            end
            ${command host}
          '';
        };
      });
    };
}
