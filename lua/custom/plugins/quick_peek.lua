return {
  'rmagatti/goto-preview',
  dependencies = { 'rmagatti/logger.nvim' },
  event = 'BufEnter',
  config = true,
  opts = {
    width = 120,
    height = 25,
    border = 'rounded',
    default_mappings = false,
    post_open_hook = function(bufnr, _)
      vim.keymap.set('n', '<Esc>', function()
        local cur = vim.api.nvim_get_current_win()
        -- floating windows have non empty "relative" field
        if vim.api.nvim_win_get_config(cur).relative ~= '' then
          vim.api.nvim_win_close(cur, false)
        else
          vim.cmd 'nohlsearch'
        end
      end, { buffer = bufnr, nowait = true, silent = true, desc = 'Close goto-preview window' })
    end,
  },
  keys = {
    { 'gpd', "<cmd>lua require('goto-preview').goto_preview_definition()<cr>" },
    { 'gpt', "<cmd>lua require('goto-preview').goto_preview_type_definition()<cr>" },
    { 'gpi', "<cmd>lua require('goto-preview').goto_preview_implementation()<cr>" },
    { 'gpc', "<cmd>lua require('goto-preview').close_all_win()<cr>" },
  },
}
