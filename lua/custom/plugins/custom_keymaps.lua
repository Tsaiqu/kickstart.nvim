return {
  vim.keymap.set('n', '<C-h>', '<C-w>h'),
  vim.keymap.set('n', '<C-j>', '<C-w>j'),
  vim.keymap.set('n', '<C-k>', '<C-w>k'),
  vim.keymap.set('n', '<C-l>', '<C-w>l'),
  vim.keymap.set('n', ']d', function()
    vim.diagnostic.jump { count = 1, float = true }
  end, { desc = 'Next [D]iagnostic' }),
  vim.keymap.set('n', '[d', function()
    vim.diagnostic.jump { count = -1, float = true }
  end, { desc = 'Prev [D]iagnostic' }),
  vim.keymap.set('n', ']e', function()
    vim.diagnostic.jump { count = 1, float = true, severity = vim.diagnostic.severity.ERROR }
  end, { desc = 'Next [E]rror' }),
  vim.keymap.set('n', '[e', function()
    vim.diagnostic.jump { count = -1, float = true, severity = vim.diagnostic.severity.ERROR }
  end, { desc = 'Prev [E]rror' }),

  -- jakbym się kiedyś skonfudował, to to są keymapy do BŁĘDÓW W KODZIE a nie diagnostyk
  vim.keymap.set('n', ']q', '<cmd>cnext<CR>', { desc = 'Next quickfix' }),
  vim.keymap.set('n', '[q', '<cmd>cprev<CR>', { desc = 'Prev quickfix' }),

  -- copy highlighted text to OS clipboard
  vim.keymap.set('v', '<leader>y', '"+y', { desc = 'Yank to system clipboard' }),

  -- disable hightligh after search
  vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>'),
}
