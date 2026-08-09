return {
  {
    'NeogitOrg/neogit',
    lazy = true,
    dependencies = {
      -- Only one of these is needed.
      'sindrets/diffview.nvim',
      'esmuellert/codediff.nvim',

      -- For a custom log pager
      'm00qek/baleia.nvim',

      -- Only one of these is needed.
      'nvim-telescope/telescope.nvim',
      'ibhagwan/fzf-lua',
      'nvim-mini/mini.pick',
      'folke/snacks.nvim',
    },
    cmd = 'Neogit',
    keys = {
      { '<leader>gg', '<cmd>Neogit<cr>', desc = 'Show Neogit UI' },
    },
    opts = {
      disable_hints = true,
      -- kind = 'floating',
      integrations = {
        telescope = true,
        diffview = true,
        fzf_lua = true,
        mini_pick = true,
      },
      log_view = { kind = 'floating' },
      popup = { kind = 'floating' },
      stash = { kind = 'floating' },
    },
  },
}
