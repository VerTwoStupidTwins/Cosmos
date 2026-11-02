{ ... }:

{
  flake.homeModules.twinsShell = { ... }: {
    programs.fish = {
      enable = true;

      preferAbbrs = true;

      interactiveShellInit = ''
        set -g fish_greeting ""
      '';

      shellAbbrs = {
        # Git
        g = "git";
        ga = "git add";
        gc = "git commit";
        gd = "git diff";
        gl = "git log --oneline --graph --decorate -12";
        gp = "git pull";
        gs = "git status --sort --branch";
        gsw = "git switch";

        # Editing
        nv = "nvim";
      };
    };

    programs.starship = {
      enable = true;
      enableFishIntegration = true;

      settings = {
        add_newline = false;
        palette = "rose_pine_moon";

        format = "$username$hostname $directory$git_branch$git_status$nix_shell$cmd_duration$line_break$character";

        # Rose Pine Moon colors
        palettes.rose_pine_moon = {
          base = "#232136";
          surface = "#2a273f";
          muted = "#6e6a86";
          subtle = "#908caa";
          text = "#e0def4";
          love = "#eb6f92";
          gold = "#f6c177";
          rose = "#ea9a97";
          pine = "#3e8fb0";
          foam = "#9ccfd8";
          iris = "#c4a7e7";
        };

        # Always show the user, including on local machines.
        username = {
          show_always = true;
          style_user = "bold iris";
          style_root = "bold love";
          format = "[$user]($style)";
        };

        # Important when working across multiple hosts.
        hostname = {
          ssh_only = false;
          style = "bold foam";
          format = "[@$hostname]($style)";
        };

        directory = {
          truncation_length = 3;
          truncate_to_repo = true;
          style = "bold text";
          format = "[$path]($style) ";
        };

        git_branch = {
          symbol = "git:";
          style = "bold iris";
          format = "[$symbol$branch]($style) ";
        };

        git_status = {
          style = "gold";
          format = "([$all_status$ahead_behind]($style) )";
        };

        # Visible inside nix develop / nix-shell.
        nix_shell = {
          symbol = "❄ ";
          style = "foam";
          format = "[$symbol$name]($style) ";
        };

        # Only show commands taking 2 seconds or longer.
        cmd_duration = {
          min_time = 2000;
          style = "muted";
          format = "[took $duration]($style) ";
        };

        character = {
          success_symbol = "[❯](bold pine) ";
          error_symbol = "[❯](bold love) ";
        };
      };
    };

    programs.eza = {
      enable = true;
      enableFishIntegration = true;
      icons = "auto";
      git = true;
    };

  };
}
