return { -- Comment/uncomment lines and blocks
  'numToStr/Comment.nvim',
  dependencies = {
    { -- Tree-sitter aware 'commentstring' (e.g. `{/* %s */}` inside JSX)
      'JoosepAlviste/nvim-ts-context-commentstring',
      init = function()
        vim.g.skip_ts_context_commentstring_module = true
      end,
    },
  },
  config = function()
    require('Comment').setup {
      -- Use tree-sitter to detect the correct commentstring based on
      -- cursor context (e.g. `{/* %s */}` inside JSX/TSX).
      pre_hook = require('ts_context_commentstring.integrations.comment_nvim').create_pre_hook(),
    }

    -- Default keymaps (kept explicit for discoverability):
    -- - gcc / gbc - toggle line / block comment on current line
    -- - gc  / gb  - toggle line / block comment on selection or motion (e.g. gcip)
  end,
}
