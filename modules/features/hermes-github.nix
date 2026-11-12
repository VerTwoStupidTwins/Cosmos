# modules/features/hermes-github.nix
{
  # Read-only GitHub access for Hermes, through GitHub's MCP server.
  flake.modules.nixos.hermes =
    { config, pkgs, ... }:
    let
      # A fine-grained token with read-only access to the chosen repositories.
      # It's read at start, because anything passed in the server's settings ends up in the Nix store.
      githubServer = pkgs.writeShellScript "github-mcp" ''
        export GITHUB_PERSONAL_ACCESS_TOKEN="$(< ${config.sops.secrets.github-token.path})"
        exec ${pkgs.github-mcp-server}/bin/github-mcp-server stdio \
          --read-only \
          --toolsets context,repos,issues,pull_requests,actions \
          --lockdown-mode
      '';
    in
    {
      sops.secrets.github-token = {
        owner = "hermes";
        mode = "0400";
        restartUnits = [
          "hermes-agent.service"
          "hermes-backend.service"
        ];
      };

      # Lockdown mode hides issue and comment text from people without push access, since anyone
      # can write on a public repository and their text would reach the agent.
      services.hermes-agent.mcpServers.github.command = "${githubServer}";
    };
}
