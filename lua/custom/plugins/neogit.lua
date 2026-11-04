return {
  {
    'NeogitOrg/neogit',
    lazy = true,
    dependencies = {
      -- Only one of these is needed.
      'sindrets/diffview.nvim',
      -- 'esmuellert/codediff.nvim',

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
    config = function()
      -- Autouzupełnianie: nazwy refów, także po "..", "..."
      _G.NeogitRangeComplete = function(arglead)
        local prefix, lead = arglead:match '^(.-%.%.%.?)(.*)$'
        if not prefix then
          prefix, lead = '', arglead
        end
        local refs = vim.fn.systemlist "git for-each-ref --format='%(refname:short)' refs/heads refs/remotes refs/tags"
        table.insert(refs, 'HEAD')
        local out = {}
        for _, r in ipairs(refs) do
          if r:find(lead, 1, true) == 1 then
            table.insert(out, prefix .. r)
          end
        end
        return out
      end

      require('neogit').setup {
        integrations = { diffview = true },
        builders = {
          NeogitDiffPopup = function(builder)
            builder:action('R', 'Range (wpisz ręcznie)', function()
              local range = vim.fn.input {
                prompt = 'Range: ',
                default = 'main...HEAD',
                completion = 'customlist,v:lua.NeogitRangeComplete',
              }
              if range ~= '' then
                vim.cmd('DiffviewOpen ' .. range)
              end
            end)
          end,
        },
      }
    end,
  },
}
