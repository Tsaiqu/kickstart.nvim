return {
  'coder/claudecode.nvim',
  dependencies = { 'folke/snacks.nvim' },
  opts = {
    focus_after_send = true,
    terminal = {
      split_side = 'left',
    },
  },
  keys = {
    { '<leader>c', nil, mode = 'x', desc = 'Claude Code' },
    { '<leader>cc', '<cmd>ClaudeCode<cr>', mode = 'x', desc = 'Toggle Claude' },
    { '<leader>cf', '<cmd>ClaudeCodeFocus<cr>', mode = 'x', desc = 'Focus Claude' },
    { '<leader>cr', '<cmd>ClaudeCode --resume<cr>', mode = 'x', desc = 'Resume Claude' },
    { '<leader>cC', '<cmd>ClaudeCode --continue<cr>', mode = 'x', desc = 'Continue Claude' },
    { '<leader>cm', '<cmd>ClaudeCodeSelectModel<cr>', mode = 'x', desc = 'Select Claude model' },
    { '<leader>cb', '<cmd>ClaudeCodeAdd %<cr>', mode = 'x', desc = 'Add current buffer' },
    { '<leader>cs', '<cmd>ClaudeCodeSend<cr>', mode = 'x', desc = 'Send selection to Claude' },
    { '<leader>ca', '<cmd>ClaudeCodeDiffAccept<cr>', mode = 'x', desc = 'Accept diff' },
    { '<leader>cd', '<cmd>ClaudeCodeDiffDeny<cr>', mode = 'x', desc = 'Deny diff' },
  },
}
