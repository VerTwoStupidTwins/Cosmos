-- Cosmos / twins: portable Neovim configuration.
-- Plugins and language servers are installed declaratively in neovim.nix.
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

local opt = vim.opt
opt.number = true
opt.relativenumber = true
opt.cursorline = true
opt.signcolumn = "yes"
opt.termguicolors = true
opt.scrolloff = 6
opt.splitbelow = true
opt.splitright = true
opt.ignorecase = true
opt.smartcase = true
opt.expandtab = true
opt.shiftwidth = 2
opt.tabstop = 2
opt.softtabstop = 2
opt.undofile = true
opt.updatetime = 250
opt.timeoutlen = 400
opt.wrap = false

-- Only use Wayland clipboard when a working Wayland session is present.
-- Avoid forcing a GUI clipboard on remote, headless SSH sessions.
if vim.env.WAYLAND_DISPLAY and vim.fn.executable("wl-copy") == 1 then
  opt.clipboard = "unnamedplus"
end

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "python" },
  callback = function()
    vim.opt_local.shiftwidth = 4
    vim.opt_local.tabstop = 4
    vim.opt_local.softtabstop = 4
  end,
})

-- Rose Pine Moon
require("rose-pine").setup({ variant = "moon", dark_variant = "moon" })
vim.cmd.colorscheme("rose-pine-moon")

-- Neovim's native Tree-sitter highlighter, with parsers supplied by Nix.
-- No TSInstall or plugin-managed downloads are needed.
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "sh", "bash", "fish", "json", "lua", "markdown", "nix", "python", "toml", "vim", "yaml" },
  callback = function(args)
    pcall(vim.treesitter.start, args.buf)
  end,
})

-- Git changes and minimal status line.
require("gitsigns").setup()
require("lualine").setup({
  options = {
    theme = "auto",
    globalstatus = true,
    component_separators = "",
    section_separators = "",
  },
})

-- Find files and search the current project.
require("telescope").setup({
  defaults = {
    sorting_strategy = "ascending",
    layout_config = { prompt_position = "top" },
  },
})
local telescope = require("telescope.builtin")
vim.keymap.set("n", "<leader>ff", telescope.find_files, { desc = "Find files" })
vim.keymap.set("n", "<leader>fg", telescope.live_grep, { desc = "Search text" })
vim.keymap.set("n", "<leader>fb", telescope.buffers, { desc = "Find buffers" })
vim.keymap.set("n", "<leader>fh", telescope.help_tags, { desc = "Find help" })
vim.keymap.set("n", "<leader>w", "<cmd>write<cr>", { desc = "Save file" })
vim.keymap.set("n", "<leader>q", "<cmd>quit<cr>", { desc = "Quit window" })

-- Completion, using Neovim's built-in snippet engine.
local cmp = require("cmp")
cmp.setup({
  snippet = {
    expand = function(args)
      vim.snippet.expand(args.body)
    end,
  },
  mapping = cmp.mapping.preset.insert({
    ["<C-Space>"] = cmp.mapping.complete(),
    ["<C-e>"] = cmp.mapping.abort(),
    ["<CR>"] = cmp.mapping.confirm({ select = false }),
    ["<Tab>"] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_next_item()
      else
        fallback()
      end
    end, { "i", "s" }),
    ["<S-Tab>"] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_prev_item()
      else
        fallback()
      end
    end, { "i", "s" }),
  }),
  sources = cmp.config.sources({
    { name = "nvim_lsp" },
    { name = "path" },
  }, {
    { name = "buffer" },
  }),
})

-- Modern Neovim 0.11+ LSP API (not legacy require('lspconfig').setup).
vim.lsp.config("lua_ls", {
  settings = {
    Lua = {
      diagnostics = { globals = { "vim" } },
      workspace = { checkThirdParty = false },
    },
  },
})

local capabilities = require("cmp_nvim_lsp").default_capabilities()
for _, server in ipairs({ "nixd", "lua_ls", "pyright", "bashls" }) do
  vim.lsp.config(server, { capabilities = capabilities })
  vim.lsp.enable(server)
end

vim.diagnostic.config({
  severity_sort = true,
  virtual_text = true,
  float = { border = "rounded" },
})

vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(event)
    local opts = { buffer = event.buf }
    vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
    vim.keymap.set("n", "gr", vim.lsp.buf.references, opts)
    vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
    vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)
    vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, opts)
  end,
})

vim.keymap.set("n", "[d", function()
  vim.diagnostic.jump({ count = -1, float = true })
end, { desc = "Previous diagnostic" })
vim.keymap.set("n", "]d", function()
  vim.diagnostic.jump({ count = 1, float = true })
end, { desc = "Next diagnostic" })
