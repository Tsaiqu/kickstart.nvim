return {
   'ThePrimeagen/harpoon',
   branch = 'harpoon2',
   dependencies = { 'nvim-lua/plenary.nvim' },
   config = function()
      require('harpoon'):setup()
      -- Przykładowe mapowania klawiszy
      vim.keymap.set('n', '<leader>a', function()
         require('harpoon'):list():add()
      end, { desc = 'Add file to Harpoon list' })

      vim.keymap.set('n', '<leader>h', function()
         local harpoon = require 'harpoon'
         harpoon.ui:toggle_quick_menu(harpoon:list())
      end, { desc = 'Toggle Harpoon Quick Menu' })
   end,
}
