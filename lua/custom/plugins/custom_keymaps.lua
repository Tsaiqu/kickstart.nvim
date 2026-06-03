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

  -- Treesitter incremental selection
  -- vim.keymap.set({ 'x' }, '[n', function()
  --   require('vim.treesitter._select').select_prev(vim.v.count1)
  -- end, { desc = 'Select previous treesitter node' }),
  --
  -- vim.keymap.set({ 'x' }, ']n', function()
  --   require('vim.treesitter._select').select_next(vim.v.count1)
  -- end, { desc = 'Select next treesitter node' }),
  --
  -- vim.keymap.set({ 'x', 'o' }, '<A-p>', function()
  --   if vim.treesitter.get_parser(nil, nil, { error = false }) then
  --     require('vim.treesitter._select').select_parent(vim.v.count1)
  --   else
  --     vim.lsp.buf.selection_range(vim.v.count1)
  --   end
  -- end, { desc = 'Select parent treesitter node or outer incremental lsp selections' }),
  --
  -- vim.keymap.set({ 'x', 'o' }, '<A-i>', function()
  --   if vim.treesitter.get_parser(nil, nil, { error = false }) then
  --     require('vim.treesitter._select').select_child(vim.v.count1)
  --   else
  --     vim.lsp.buf.selection_range(-vim.v.count1)
  --   end
  -- end, { desc = 'Select child treesitter node or inner incremental lsp selections' }),
}
