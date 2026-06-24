return {
  'nvim-lualine/lualine.nvim',
  dependencies = { 'nvim-tree/nvim-web-devicons' },
  opts = {
    options = {
      theme = 'catppuccin-nvim',
      section_separators = { left = '', right = '' },
      component_separators = '',
      icons_enabled = true,
    },
    sections = {
      lualine_a = { 'mode' },
      lualine_b = {
        {
          'branch',
          fmt = function(name)
            -- grab the first "word" (leading run of letters/digits);
            -- stops at the first separator: - _ / . etc.
            local first = name:match '^%w+'
            if first and #first < #name then
              return first .. '…'
            end
            return name
          end,
        },
        'diff',
        'diagnostics',
      },
      lualine_c = { 'filename' },
      lualine_x = { 'filetype' },
      lualine_y = { 'progress' },
      lualine_z = { 'location' },
    },
  },
}
