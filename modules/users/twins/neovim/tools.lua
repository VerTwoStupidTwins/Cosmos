-- Cosmos / twins: formatting and linting.
-- All executables are supplied by the Home Manager Neovim module.

-- Format synchronously before writing so disk content matches the editor.
require("conform").setup({
  formatters_by_ft = {
    nix = { "nixfmt" },
    python = { "ruff_format" },
    lua = { "stylua" },
    sh = { "shfmt" },
    bash = { "shfmt" },
    fish = { "fish_indent" },
  },
  format_on_save = {
    timeout_ms = 2000,
    lsp_format = "never", -- avoid overlapping LSP formatters
  },
})

-- Explicit format command for when you don't want to save yet.
vim.keymap.set("n", "<leader>cf", function()
  require("conform").format({ async = true, lsp_format = "never" })
end, { desc = "Format buffer" })

-- LSPs handle semantic/type diagnostics. Standalone linters add targeted checks.
local lint = require("lint")
lint.linters_by_ft = {
  nix = { "statix", "deadnix" },
  python = { "ruff" },
  sh = { "shellcheck" },
  bash = { "shellcheck" },
  fish = { "fish" },
}

local lint_group = vim.api.nvim_create_augroup("CosmosLint", { clear = true })
vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
  group = lint_group,
  callback = function()
    lint.try_lint()
  end,
})

vim.keymap.set("n", "<leader>cl", function()
  lint.try_lint()
end, { desc = "Lint buffer" })
