return {
  -- REMEMBER those settings require you to have installed
  -- basedpyright as well as ruff globally and available via $PATH
  -- tip: you can install them by `pipx`
  vim.lsp.config('basedpyright', { capabilities = require('blink.cmp').get_lsp_capabilities() }),
  vim.lsp.enable 'basedpyright',
  vim.lsp.config('ruff', { capabilities = require('blink.cmp').get_lsp_capabilities() }),
  vim.lsp.enable 'ruff',
}
