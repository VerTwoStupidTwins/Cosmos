# modules/git-hooks.nix
# Checks before each commit, from git-hooks.nix: formatting (the flake's own formatter, so the same as `nix fmt`) and
# dead code (deadnix). Entering the dev shell installs them; on tenjin direnv does that on `cd /Cosmos` (.envrc,
# modules/features/deploy.nix). A misformatted file is formatted in place and the commit stops, to look and add again.
# The same hooks run over the whole repo as `checks.<system>.pre-commit`, which is what CI runs, so the two can't
# disagree.
{ inputs, ... }:
{
  imports = [ inputs.git-hooks.flakeModule ];

  perSystem =
    { config, pkgs, ... }:
    {
      pre-commit.settings.hooks = {
        treefmt = {
          enable = true;
          package = pkgs.nixfmt-tree;
        };
        deadnix.enable = true;
      };

      devShells.default = pkgs.mkShellNoCC {
        shellHook = config.pre-commit.installationScript;
      };
    };
}
