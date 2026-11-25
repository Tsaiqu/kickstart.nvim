local interval_ms = 2000

local focused = true
local running = false
local snapshots = {}

local function visible_tree_state()
  local ok, manager = pcall(require, 'neo-tree.sources.manager')
  if not ok then
    return
  end
  local state = manager.get_state 'filesystem'
  if state.path and require('neo-tree.ui.renderer').window_exists(state) then
    return state
  end
end

local function check()
  if running or not focused or vim.bo.filetype == 'neo-tree-popup' then
    return
  end
  local state = visible_tree_state()
  if not state then
    return
  end
  local path = state.path
  running = true
  vim.system(
    { 'git', '--no-optional-locks', '-C', path, 'status', '--porcelain=v2', '-z', '--untracked-files=normal', '--', '.' },
    { text = true },
    vim.schedule_wrap(function(result)
      running = false
      if result.code ~= 0 then
        snapshots[path] = nil
        return
      end
      local previous = snapshots[path]
      snapshots[path] = result.stdout
      if previous ~= nil and previous ~= result.stdout then
        require('neo-tree.sources.manager').refresh 'filesystem'
      end
    end)
  )
end

local timer = assert((vim.uv or vim.loop).new_timer())
timer:start(interval_ms, interval_ms, vim.schedule_wrap(check))

local group = vim.api.nvim_create_augroup('custom-neo-tree-autorefresh', { clear = true })

vim.api.nvim_create_autocmd('FocusLost', {
  group = group,
  callback = function()
    focused = false
  end,
})

vim.api.nvim_create_autocmd({ 'FocusGained', 'TermLeave', 'BufWritePost' }, {
  group = group,
  callback = function(args)
    if args.event == 'FocusGained' then
      focused = true
    end
    check()
  end,
})

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = group,
  callback = function()
    timer:stop()
    timer:close()
  end,
})

return {}
