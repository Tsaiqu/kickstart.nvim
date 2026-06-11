return {
  'ThePrimeagen/harpoon',
  branch = 'harpoon2',
  dependencies = { 'nvim-lua/plenary.nvim' },
  config = function()
    require('harpoon'):setup()
    -- Przykładowe mapowania klawiszy
    vim.keymap.set('n', '<leader>a', function()
      require('harpoon'):list():add()
    end, { desc = '[A]dd file to Harpoon list' })

    vim.keymap.set('n', '<leader>H', function()
      local harpoon = require 'harpoon'
      harpoon.ui:toggle_quick_menu(harpoon:list())
    end, { desc = 'Toggle [H]arpoon Quick Menu' })

    vim.api.nvim_create_autocmd('FileType', {
      pattern = 'harpoon',
      callback = function(ev)
        for i = 1, 4 do
          vim.keymap.set('n', tostring(i), function()
            vim.api.nvim_win_close(0, true)
            require('harpoon'):list():select(i)
          end, { buffer = ev.buf, nowait = true })
        end
      end,
    })
  end,
}
