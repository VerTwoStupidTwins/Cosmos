# modules/features/hermes-claude.nix
{
  # Research subagents run on Claude through the owner's subscription. The main model stays local.
  flake.modules.nixos.hermes =
    { lib, pkgs, ... }:
    let
      # Nous Research's reviewed plugin, pinned to the commit Hermes' plugin catalog lists.
      claudePlugin = pkgs.runCommand "claude-subscription-directsdk" { } ''
        cp -r ${
          pkgs.fetchFromGitHub {
            owner = "NousResearch";
            repo = "hermes-official-plugins";
            rev = "e7a218f26db88426ab3e7376f0e000b6e356f5e7";
            hash = "sha256-zDjiWUVmWUPAyasy74mUuh+d/dpBi1SBh7GZvuTjxcI=";
          }
        }/claude-subscription-directsdk $out
      '';

      researchRoutingPlugin = pkgs.runCommand "research-routing" { } ''
        cp -r ${./hermes-research-routing} $out
      '';
    in
    {
      services.hermes-agent = {
        # The plugin sends every request through the official CLI, which holds the login.
        # Log in once as the hermes user: sudo -u hermes -H claude auth login
        extraPackages = [ pkgs.claude-code ];
        environment.CLAUDE_SUBSCRIPTION_DIRECTSDK_COMMAND = lib.getExe pkgs.claude-code;

        extraPlugins = [
          claudePlugin
          researchRoutingPlugin
        ];

        # research-routing is also listed in plugins.enabled in hermes.nix, since that list doesn't merge across files.
        settings.delegation = {
          backend = "research-routing";
          backends.research-routing = {
            # Everyday research, which uses less of the subscription's allowance.
            model = "sonnet";
            # Deep dives, only when asked for one.
            deep_model = "opus";
          };
        };
      };
    };
}
