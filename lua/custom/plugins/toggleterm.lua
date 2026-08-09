return {
  'akinsho/toggleterm.nvim',
  version = '*',
  opts = {
    shade_terminals = false,
    open_mapping = [[<C-\>]],
    direction = 'horizontal',
    size = 15,
  },
  config = function(_, opts)
    require('toggleterm').setup(opts)

    local Terminal = require('toggleterm.terminal').Terminal

    for i = 1, 3 do
      vim.keymap.set('n', '<leader>t' .. i, '<cmd>' .. i .. 'ToggleTerm direction=horizontal<CR>', { desc = 'Toggle terminal ' .. i .. ' (horizontal)' })
    end

    local float_term = Terminal:new { direction = 'float' }
    vim.keymap.set('n', '<leader>tf', function()
      float_term:toggle()
    end, { desc = 'Toggle floating terminal' })

    vim.keymap.set('n', '<leader>tv', '<cmd>ToggleTerm direction=vertical size=80<CR>', { desc = 'Toggle vertical terminal' })
  end,
}
