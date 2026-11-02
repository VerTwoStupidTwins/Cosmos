
{ ... }:

{
  flake.homeModules.twinsYazi = { ... }: {
    programs.yazi = {
      enable = true;
      enableFishIntegration = true;

      # The wrapper remembers the directory you exit in.
      shellWrapperName = "yy";

      settings = {
        mgr = {
          # Parent | Current | Preview
          ratio = [ 1 4 3 ];

          sort_by = "alphabetical";
          sort_dir_first = true;
          show_hidden = true;

          scrolloff = 5;
        };
      };

      theme = {
        mgr = {
          cwd = {
            fg = "#9ccfd8";
          };

          find_keyword = {
            fg = "#f6c177";
            bold = true;
            italic = true;
            underline = true;
          };

          find_position = {
            fg = "#c4a7e7";
            bold = true;
          };

          border_style = {
            fg = "#6e6a86";
          };

          marker_copied = {
            fg = "#3e8fb0";
            bg = "#3e8fb0";
          };

          marker_cut = {
            fg = "#eb6f92";
            bg = "#eb6f92";
          };

          marker_selected = {
            fg = "#f6c177";
            bg = "#f6c177";
          };
        };

        tabs = {
          active = {
            fg = "#232136";
            bg = "#c4a7e7";
            bold = true;
          };

          inactive = {
            fg = "#908caa";
            bg = "#2a273f";
          };
        };

        mode = {
          normal_main = {
            fg = "#232136";
            bg = "#c4a7e7";
            bold = true;
          };

          normal_alt = {
            fg = "#e0def4";
            bg = "#393552";
          };

          select_main = {
            fg = "#232136";
            bg = "#f6c177";
            bold = true;
          };

          select_alt = {
            fg = "#e0def4";
            bg = "#393552";
          };

          unset_main = {
            fg = "#232136";
            bg = "#eb6f92";
            bold = true;
          };

          unset_alt = {
            fg = "#e0def4";
            bg = "#393552";
          };
        };

        status = {
          perm_type.fg = "#9ccfd8";
          perm_read.fg = "#f6c177";
          perm_write.fg = "#eb6f92";
          perm_exec.fg = "#3e8fb0";
        };

        which = {
          border.fg = "#c4a7e7";
          cand.fg = "#9ccfd8";
          desc.fg = "#c4a7e7";
        };
      };
    };
  };
}

