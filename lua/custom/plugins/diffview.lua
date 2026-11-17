-- `<leader>gd`: wraca do już otwartego diffview zmian roboczych (bez rewizji w argumentach, np. nie
-- diffview PR-a otwarty z azure_pr) dla tego samego repo i odświeża listę plików; inaczej otwiera nowy.
-- Dzięki temu po `gf` (plik otwiera się w poprzedniej karcie) skrót nie mnoży kart z diffview.
local function diffview_open_or_focus()
  local ok, lib = pcall(require, 'diffview.lib')
  local RevType = ok and require('diffview.vcs.rev').RevType
  local toplevel = vim.fs.root(0, '.git') or vim.fn.getcwd()
  toplevel = vim.fs.normalize(vim.fn.fnamemodify(toplevel, ':p'))
  for _, view in ipairs(ok and lib.views or {}) do
    local working_tree = view.right and view.right.type == RevType.LOCAL and (view.rev_arg == nil or view.rev_arg == '')
    local root = view.adapter and view.adapter.ctx and view.adapter.ctx.toplevel
    local same_repo = root and vim.fs.normalize(vim.fn.fnamemodify(root, ':p')) == toplevel
    if working_tree and same_repo and view.tabpage and vim.api.nvim_tabpage_is_valid(view.tabpage) then
      vim.api.nvim_set_current_tabpage(view.tabpage)
      vim.cmd 'DiffviewRefresh'
      return
    end
  end
  vim.cmd 'DiffviewOpen'
end

return {
  {
    'sindrets/diffview.nvim',
    cmd = { 'DiffviewOpen', 'DiffviewClose', 'DiffviewFileHistory', 'DiffviewToggleFiles' },
    keys = {
      { '<leader>gd', diffview_open_or_focus, desc = 'Git [d]iff side by side (reuse open view)' },
      { '<leader>gc', '<cmd>DiffviewClose<cr>', desc = 'Git diff [c]lose' },
      { '<leader>gh', '<cmd>DiffviewFileHistory %<cr>', desc = 'Git file [h]istory' },
      { '<leader>gH', '<cmd>DiffviewFileHistory<cr>', desc = 'Git branch [H]istory' },
    },
    opts = {
      enhanced_diff_hl = true,
      view = {
        default = { layout = 'diff2_horizontal' },
        merge_tool = { layout = 'diff3_mixed' },
      },
    },
  },
}
