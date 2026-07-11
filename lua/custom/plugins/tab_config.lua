return {
  vim.keymap.set('n', '<S-l>', 'gt', { desc = 'Next tab', silent = true }),
  vim.keymap.set('n', '<S-h>', 'gT', { desc = 'Previous tab', silent = true }),
}
