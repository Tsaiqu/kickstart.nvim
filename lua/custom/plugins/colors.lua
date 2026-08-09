return {
  {
    'sainnhe/sonokai',
    lazy = false,
    priority = 1000,
    config = function()
      vim.g.sonokai_style = 'andromeda'
    end,
  },
  { -- You can easily change to a different colorscheme.
    -- Change the name of the colorscheme plugin below, and then
    -- change the command in the config to whatever the name of that colorscheme is.
    --
    -- If you want to see what colorschemes are already installed, you can use `:Telescope colorscheme`.
    'folke/tokyonight.nvim',
    priority = 1000, -- Make sure to load this before all the other start plugins.
    config = function()
      ---@diagnostic disable-next-line: missing-fields
      require('tokyonight').setup {
        styles = {
          comments = { italic = false }, -- Disable italics in comments
        },
      }
    end,
  },

  {
    'catppuccin/nvim',
    priority = 1001,
    name = 'catppuccin',
    config = function()
      require('catppuccin').setup {
        flavour = 'mocha',
        custom_highlights = function(colors)
          return {
            -- explicit fields (not `link`) so catppuccin's own bg/fg/bold
            -- for this group don't survive the tbl_deep_extend("keep", ...) merge
            TelescopeSelection = { bg = colors.surface0, fg = 'NONE', bold = false },
            TelescopeSelectionCaret = { fg = '#e0af68', bold = true },
          }
        end,
      }
      vim.cmd.colorscheme 'catppuccin'
    end,
  },
}
