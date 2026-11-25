return {
  'coder/claudecode.nvim',
  dependencies = { 'folke/snacks.nvim' },
  init = function()
    vim.api.nvim_create_autocmd('FileType', {
      pattern = 'claudecode',
      callback = function(args)
        for _, key in ipairs { 'h', 'l' } do
          vim.keymap.set('t', '<C-' .. key .. '>', '<C-\\><C-n><C-w>' .. key, {
            buffer = args.buf,
            desc = 'Leave terminal and move to window ' .. key,
          })
        end
      end,
    })
  end,
  opts = {
    focus_after_send = true,
    terminal = {
      split_side = 'left',
    },
  },
  keys = {
    { '<leader>c', nil, mode = { 'n', 'x' }, desc = 'Claude Code' },
    { '<leader>cc', '<cmd>ClaudeCode<cr>', mode = { 'n', 'x' }, desc = 'Toggle Claude' },
    { '<leader>cf', '<cmd>ClaudeCodeFocus<cr>', mode = { 'n', 'x' }, desc = 'Focus Claude' },
    { '<leader>cr', '<cmd>ClaudeCode --resume<cr>', mode = { 'n', 'x' }, desc = 'Resume Claude' },
    { '<leader>cC', '<cmd>ClaudeCode --continue<cr>', mode = { 'n', 'x' }, desc = 'Continue Claude' },
    { '<leader>cm', '<cmd>ClaudeCodeSelectModel<cr>', mode = { 'n', 'x' }, desc = 'Select Claude model' },
    { '<leader>cb', '<cmd>ClaudeCodeAdd %<cr>', mode = { 'n', 'x' }, desc = 'Add current buffer' },
    { '<leader>cs', '<cmd>ClaudeCodeSend<cr>', mode = 'x', desc = 'Send selection to Claude' },
    { '<leader>ca', '<cmd>ClaudeCodeDiffAccept<cr>', mode = { 'n', 'x' }, desc = 'Accept diff' },
    { '<leader>cd', '<cmd>ClaudeCodeDiffDeny<cr>', mode = { 'n', 'x' }, desc = 'Deny diff' },
  },
}
