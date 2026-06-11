return {
  'folke/noice.nvim',
  event = 'VeryLazy',
  opts = {
    -- any options go here
  },
  dependencies = {
    -- if you lazy-load any plugin below, make sure to add proper `module="..."` entries
    'MunifTanjim/nui.nvim',
    -- OPTIONAL:
    -- 	`nvim-notify` is needed, if you want to use the notification view.
    -- 	If not available, we use `mini` as the fallback
    {
      'rcarriga/nvim-notify',
      opts = {
        background_color = '#1e1e2e',
      },
    },
  },
}
