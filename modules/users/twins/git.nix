{ ... }:

{
  flake.homeModules.twinsGit = { ... }: {
    programs.git = {
      enable = true;

      settings = {
        user = {
          name = "twins";
          email = "twins@mail.com";
          useConfigOnly = true;
        };

        init.defaultBranch = "main";

        core.editor = "nvim";

        # Prevent accidental merge commits during pulls.
        pull.ff = "only";

        # Clean up references to deleted remote branches.
        fetch.prune = true;

        # Set upstream automatically for new branches.
        push.autoSetupRemote = true;

        # Improve diffs and conflict handling.
        diff.algorithm = "histogram";
        merge.conflictStyle = "zdiff3";

        # Remember conflict resolutions.
        rerere.enabled = true;

        # Show changes in the commit editor.
        commit.verbose = true;
      };

      ignores = [
        "*.swp"
        "*.swo"
        "*~"
        ".direnv/"
      ];
    };
  };
}
