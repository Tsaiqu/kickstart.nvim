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
  end,
}
