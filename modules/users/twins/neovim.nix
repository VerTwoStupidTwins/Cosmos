{ ... }:

{
  flake.homeModules.twinsNeovim = { pkgs, ... }: {
    programs.neovim = {
      enable = true;
      defaultEditor = true;
      viAlias = true;
      vimAlias = true;

      # Plugins are provided by Nix. No plugin manager or runtime downloads.
      plugins = with pkgs.vimPlugins; [
        rose-pine
        plenary-nvim
        telescope-nvim
        gitsigns-nvim
        lualine-nvim
        nvim-lspconfig
        conform-nvim
        nvim-lint
        nvim-cmp
        cmp-nvim-lsp
        cmp-buffer
        cmp-path

        # New nvim-treesitter API, parsers built by Nix.
        (nvim-treesitter.withPlugins (p: with p; [
          bash fish json lua markdown markdown_inline
          nix python toml vim vimdoc yaml
        ]))
      ];

      # These are on Neovim's PATH, on both graphical and SSH hosts.
      extraPackages = with pkgs; [
        nixd
        lua-language-server
        pyright
        bash-language-server

        # Formatters and linters available inside Neovim on every host.
        nixfmt
        statix
        deadnix
        ruff
        stylua
        shfmt
        shellcheck
        fish # provides fish_indent and fish --no-execute

        ripgrep
        fd
      ];

      # Keep the original working editor config intact; add tooling after it.
      initLua = builtins.concatStringsSep "\n" [
        (builtins.readFile ./neovim/init.lua)
        (builtins.readFile ./neovim/tools.lua)
      ];
    };
  };
}
