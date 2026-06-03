return {
  'Fildo7525/pretty_hover',
  event = 'LspAttach',
  opts = {
    border = 'rounded',
    wrap = true,
    max_width = 100,
    max_height = 30,
    toggle = false,
    multi_server = true,

    hl = {
      error = {
        color = '#DC2626',
        detect = { '[\\@]error', '[\\@]bug' },
      },

      warning = {
        color = '#FBBF24',
        detect = {
          '[\\@]warning',
          '[\\@]thread_safety',
          '[\\@]thow',
        },
      },

      info = {
        color = '#2563EB',
        detect = {
          '[\\@]remark',
          '[\\@]note',
          '[\\@]notes',
        },
      },
    },
  },
  keys = {
    {
      'K',
      function()
        require('pretty_hover').hover()
      end,
      desc = 'Pretty hover',
    },

    {
      '<leader>lh',
      function()
        require('pretty_hover').hover()
      end,
      desc = 'Open Pretty Hover',
    },

    {
      '<leader>lc',
      function()
        require('pretty_hover').close()
      end,
      desc = 'Close Pretty Hover',
    },
  },
}
