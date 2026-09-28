-- azure_pr: Azure DevOps pull requests inside Neovim.
-- Entry point: setup(), the :AzurePR user command and optional global keymaps.
-- setup() is cheap: no network and no git calls happen until a command is used.
local M = {}

---Lazily require a submodule (UI modules are only loaded when a command runs).
---@param name string
local function mod(name)
  return require('azure_pr.' .. name)
end

local function notify(msg, level)
  local ok, util = pcall(require, 'azure_pr.util')
  if ok and util.notify then
    util.notify(msg, level)
  else
    vim.notify(msg, level, { title = 'Azure PR' })
  end
end

M.STATUSES = { 'active', 'completed', 'abandoned', 'all' }

---Open the PR list.
---@param opts table|nil { filters?, group_by?, status? }
function M.list(opts)
  mod('ui.list').open(opts or {})
end

---Open the PR list filtered to PRs created by me.
function M.mine()
  M.list { filters = { created_by_me = true } }
end

---Open the review queue (PRs that need my vote).
function M.review()
  -- the review queue only makes sense for active PRs, whatever status the list showed last
  M.list { filters = { needs_my_vote = true }, status = 'active' }
end

---Open the detail view of a PR by its (project-level) id.
---@param id integer|string
function M.open(id)
  -- accept the `!123` form shown everywhere in the UI
  local n = tonumber(type(id) == 'string' and (id:gsub('^%s*!', '')) or id)
  if not n then
    return notify('Usage: :AzurePR open [!]<pr id>', vim.log.levels.WARN)
  end
  notify('Loading PR !' .. n .. '…', vim.log.levels.INFO)
  mod('api').get_pull_request_by_id(n, function(err, raw)
    if err or not raw then
      return notify('Cannot load PR !' .. n .. ': ' .. tostring(err or 'not found'), vim.log.levels.ERROR)
    end
    local pr = mod('models').normalize_pr(raw)
    local api = mod 'api'
    if not pr.url and api.web_url then
      local ok, url = pcall(api.web_url, pr)
      pr.url = ok and url or nil
    end
    mod('ui.detail').open(pr)
  end)
end

---Open the detail view of the PR whose source branch is the current git branch.
function M.current()
  mod('actions').current_branch_pr(function(err, pr)
    -- Tolerate a cb(pr) style callback as well.
    if type(err) == 'table' and pr == nil then
      err, pr = nil, err
    end
    if err then
      return notify(tostring(err), vim.log.levels.ERROR)
    end
    if pr then
      mod('ui.detail').open(pr)
    end
  end)
end

---Comment on the given line range of the current file buffer.
---@param opts table|nil { line1?, line2?, buf?, pr_id? }
function M.comment(opts)
  opts = opts or {}
  if not opts.line1 then
    local l = vim.api.nvim_win_get_cursor(0)[1]
    opts.line1, opts.line2 = l, l
  end
  opts.line2 = opts.line2 or opts.line1
  if opts.line2 < opts.line1 then
    opts.line1, opts.line2 = opts.line2, opts.line1
  end
  opts.buf = opts.buf or vim.api.nvim_get_current_buf()
  mod('actions').comment_on_line(opts)
end

---Refresh the current azure_pr view (detail when inside one, otherwise the list).
function M.refresh()
  if vim.bo.filetype == 'azure_pr_detail' then
    local ok, detail = pcall(require, 'azure_pr.ui.detail')
    if ok and detail.refresh then
      return detail.refresh()
    end
  end
  mod('ui.list').refresh()
end

---Forget cached PRs, user, PAT and resolved organization/project.
function M.clear_cache()
  mod('state').reset()
  mod('config').clear_cache()
  local ok, api = pcall(require, 'azure_pr.api')
  if ok and api.clear_cache then
    api.clear_cache()
  end
  notify('Azure PR caches cleared', vim.log.levels.INFO)
end

---Subcommand table. `fn(args, cmd_opts)`; `complete(arglead)` optional.
---@type table<string, {fn: fun(args: string[], cmd: table), complete?: (fun(lead: string): string[]), desc: string}>
M.subcommands = {
  list = {
    desc = 'List PRs [status]',
    fn = function(args)
      local status = args[1]
      if status and not vim.tbl_contains(M.STATUSES, status) then
        return notify('Unknown status "' .. status .. '" (use: ' .. table.concat(M.STATUSES, ', ') .. ')', vim.log.levels.WARN)
      end
      M.list { status = status }
    end,
    complete = function()
      return M.STATUSES
    end,
  },
  mine = {
    desc = 'PRs created by me',
    fn = function()
      M.mine()
    end,
  },
  review = {
    desc = 'PRs that need my vote',
    fn = function()
      M.review()
    end,
  },
  open = {
    desc = 'Open PR <id>',
    fn = function(args)
      M.open(args[1])
    end,
  },
  current = {
    desc = 'PR of the current branch',
    fn = function()
      M.current()
    end,
  },
  comment = {
    desc = 'Comment on line / [range] [pr id]',
    fn = function(args, cmd)
      local pr_id = args and args[1] and (args[1]:gsub('^!', '')) or nil
      if cmd.range and cmd.range > 0 then
        M.comment { line1 = cmd.line1, line2 = cmd.line2, pr_id = pr_id }
      else
        M.comment { pr_id = pr_id }
      end
    end,
  },
  refresh = {
    desc = 'Refresh current view',
    fn = function()
      M.refresh()
    end,
  },
  clear_cache = {
    desc = 'Clear caches',
    fn = function()
      M.clear_cache()
    end,
  },
  health = {
    desc = 'Run :checkhealth azure_pr',
    fn = function()
      vim.cmd 'checkhealth azure_pr'
    end,
  },
}

---@return string[] sorted subcommand names
function M.subcommand_names()
  local names = vim.tbl_keys(M.subcommands)
  table.sort(names)
  return names
end

---Completion function for :AzurePR.
---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
  -- Strip optional range and command name: "'<,'>AzurePR comment" -> "comment"
  local rest = cmdline:match 'AzurePR!?%s+(.*)$'
  local words = rest and vim.split(rest, '%s+', { trimempty = true }) or {}
  -- Number of fully typed words before the one being completed.
  local done = #words - (arglead ~= '' and 1 or 0)
  local candidates
  if done == 0 then
    candidates = M.subcommand_names()
  elseif done == 1 then
    local sub = M.subcommands[words[1]]
    candidates = sub and sub.complete and sub.complete(arglead) or {}
  else
    candidates = {}
  end
  return vim.tbl_filter(function(c)
    return vim.startswith(c, arglead)
  end, candidates)
end

---Dispatch :AzurePR.
---@param cmd table nvim_create_user_command callback argument
function M.command(cmd)
  local args = vim.deepcopy(cmd.fargs or {})
  local name = table.remove(args, 1)
  if not name then
    -- A plain :'<,'>AzurePR with a range means "comment on these lines".
    if cmd.range and cmd.range > 0 then
      return M.subcommands.comment.fn(args, cmd)
    end
    return M.list {}
  end
  local sub = M.subcommands[name]
  if not sub then
    return notify('Unknown subcommand "' .. name .. '". Available: ' .. table.concat(M.subcommand_names(), ', '), vim.log.levels.WARN)
  end
  local ok, err = pcall(sub.fn, args, cmd)
  if not ok then
    notify('AzurePR ' .. name .. ' failed: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

-- Global keymaps set by the previous setup() call: { {mode, lhs}, ... }
local mapped = {}

local function as_list(v)
  if v == nil or v == false then
    return {}
  end
  return type(v) == 'table' and v or { v }
end

local function clear_global_keymaps()
  for _, m in ipairs(mapped) do
    pcall(vim.keymap.del, m[1], m[2])
  end
  mapped = {}
end

local function map(modes, lhs_value, rhs, desc)
  for _, lhs in ipairs(as_list(lhs_value)) do
    for _, mode in ipairs(modes) do
      vim.keymap.set(mode, lhs, rhs, { desc = desc, silent = true })
      table.insert(mapped, { mode, lhs })
    end
  end
end

local function comment_visual()
  local l1, l2 = vim.fn.line 'v', vim.fn.line '.'
  -- Leave visual mode before opening the comment float.
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
  M.comment { line1 = math.min(l1, l2), line2 = math.max(l1, l2) }
end

local function setup_global_keymaps(cfg)
  clear_global_keymaps()
  local g = cfg.keymaps and cfg.keymaps.global
  if not g or g.enabled == false then
    return
  end
  map({ 'n' }, g.list, function()
    M.list {}
  end, 'Azure [P]R [L]ist')
  map({ 'n' }, g.mine, M.mine, 'Azure [P]R [M]ine')
  map({ 'n' }, g.review, M.review, 'Azure [P]R [R]eview queue')
  map({ 'n' }, g.current, M.current, 'Azure [P]R [C]urrent branch')
  map({ 'n' }, g.comment, function()
    M.comment {}
  end, 'Azure [P]R comment ([A]dd) on line')
  map({ 'x' }, g.comment, comment_visual, 'Azure [P]R comment ([A]dd) on lines')
  M._register_which_key_group(g)
end

--- Label the `<leader>p` prefix in which-key (when the default-style mappings use it). Does not
--- load which-key during startup: registers now if it is loaded (or startup is over), else after VimEnter.
---@param g table keymaps.global
function M._register_which_key_group(g)
  local prefix = g.group_prefix or '<leader>p'
  local used = false
  for _, k in ipairs { 'list', 'mine', 'review', 'current', 'comment' } do
    local v = g[k]
    for _, lhs in ipairs(type(v) == 'table' and v or { v }) do
      if type(lhs) == 'string' and lhs:sub(1, #prefix) == prefix and #lhs > #prefix then
        used = true
      end
    end
  end
  if not used then
    return
  end
  local function add()
    local ok, wk = pcall(require, 'which-key')
    if ok and type(wk) == 'table' and type(wk.add) == 'function' then
      pcall(wk.add, { { prefix, group = 'Azure [P]R', mode = { 'n', 'x' } } })
    end
  end
  if package.loaded['which-key'] or vim.v.vim_did_enter == 1 then
    add()
  else
    -- after startup (scheduled past VimEnter, when lazy-loaded plugins such as which-key are up)
    vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = vim.schedule_wrap(add) })
  end
end

---Configure the plugin. Safe to call multiple times.
---@param opts table|nil see azure_pr.config defaults
function M.setup(opts)
  local config = mod 'config'
  config.setup(opts or {})
  mod('ui.highlights').setup()
  local cfg = config.get()

  vim.api.nvim_create_user_command('AzurePR', M.command, {
    nargs = '*',
    range = true,
    complete = M.complete,
    desc = 'Azure DevOps pull requests',
    force = true,
  })

  setup_global_keymaps(cfg)
  M._did_setup = true
end

return M
