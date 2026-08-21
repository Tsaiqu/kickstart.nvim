return {
  vim.keymap.set('n', '<A-l>', 'gt', { desc = 'Next tab', silent = true }),
  vim.keymap.set('n', '<A-h>', 'gT', { desc = 'Previous tab', silent = true }),
}
