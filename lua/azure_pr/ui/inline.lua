-- Inline PR thread markers (sign + end-of-line hint) in code buffers and ]t/[t navigation.
local frame = require 'azure_pr.ui.frame'
local hl = require 'azure_pr.ui.highlights'

local M = {}

M.ns = vim.api.nvim_create_namespace 'azure_pr_inline'

local HINT_WIDTH = 80

--- Per-buffer state: { marks = { { lnum, thread_ids, threads } }, keys = { lhs... }, pr = PR given to place }
local state = {}

local function is_open(status)
  return status == 'active' or status == 'pending' or status == 'unknown'
end

local function visible_text_comments(thread)
  local out = {}
  for _, c in ipairs(thread.comments or {}) do
    if not c.is_deleted and (c.type == nil or c.type == 'text') then
      out[#out + 1] = c
    end
  end
  return out
end

local function truncate(s, max)
  if frame.dw(s) <= max then
    return s
  end
  local ell = hl.icons().ellipsis
  local out, w = {}, 0
  for _, ch in ipairs(vim.fn.split(s, '\\zs')) do
    local cw = frame.dw(ch)
    if w + cw > max - frame.dw(ell) then
      break
    end
    out[#out + 1] = ch
    w = w + cw
  end
  return table.concat(out) .. ell
end

--- "<author>: <first line of first comment> (+N)" cut to `max_width` display cells.
---@param thread table
---@param max_width integer
---@return string
function M.hint(thread, max_width)
  local comments = visible_text_comments(thread)
  local first = comments[1]
  if not first then
    return ''
  end
  local author = first.author and first.author.name or '?'
  local line = vim.split(first.content or '', '\n', { plain = true })[1] or ''
  line = vim.trim(line)
  local suffix = #comments > 1 and (' (+' .. (#comments - 1) .. ')') or ''
  local head = truncate(author .. ': ' .. line, math.max(max_width - frame.dw(suffix), 1))
  return head .. suffix
end

local function lhs_list(v)
  if not v then
    return {}
  end
  if type(v) == 'string' then
    return { v }
  end
  return v
end

local function nav_keys()
  local ok, config = pcall(require, 'azure_pr.config')
  local km = {}
  if ok then
    local defaults = config.defaults and config.defaults.keymaps and config.defaults.keymaps.detail or {}
    local okc, cur = pcall(config.get)
    local user = okc and type(cur) == 'table' and cur.keymaps and cur.keymaps.detail or {}
    km = vim.tbl_extend('force', defaults, user)
  end
  return { next = lhs_list(km.next_thread), prev = lhs_list(km.prev_thread) }
end

local function use_icons()
  local ok, config = pcall(require, 'azure_pr.config')
  if ok then
    local okc, cur = pcall(config.get)
    if okc and type(cur) == 'table' and cur.icons ~= nil then
      return cur.icons and true or false
    end
  end
  return nil
end

--- Remove marks, keymaps and stored data of `buf`.
---@param buf integer
function M.detach(buf)
  local st = state[buf]
  state[buf] = nil
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, buf, M.ns, 0, -1)
  if st then
    for _, lhs in ipairs(st.keys) do
      pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
    end
  end
  pcall(function()
    vim.b[buf].azure_pr_inline = nil
  end)
end

local function set_keys(buf, st)
  if st.keys then
    return
  end
  st.keys = {}
  local keys = nav_keys()
  for _, spec in ipairs { { keys.next, 1, 'Next thread' }, { keys.prev, -1, 'Previous thread' } } do
    for _, lhs in ipairs(spec[1]) do
      -- never override (or later delete) a buffer-local mapping we did not create
      local existing = vim.api.nvim_buf_call(buf, function()
        return vim.fn.maparg(lhs, 'n', false, true)
      end)
      if not (type(existing) == 'table' and existing.buffer == 1) then
        vim.keymap.set('n', lhs, function()
          M.jump(buf, spec[2])
        end, { buffer = buf, silent = true, desc = 'Azure PR: ' .. spec[3] })
        st.keys[#st.keys + 1] = lhs
      end
    end
  end
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      state[buf] = nil
    end,
  })
end

---@param buf integer
---@param pr table
---@param threads table[]
---@param opts { side: string, path: string }
function M.place(buf, pr, threads, opts)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  local old = state[buf]
  local st = { marks = {}, keys = old and old.keys or nil, pr = pr }
  state[buf] = st

  local icons = hl.icons(use_icons())
  local api = require 'azure_pr.api'
  local want = api._thread_file_path(opts.path)
  local count = vim.api.nvim_buf_line_count(buf)

  local by_line, order = {}, {}
  for _, t in ipairs(threads or {}) do
    if
      not t.is_system
      and t.file_path
      and t.line
      and t.side
      and t.side == opts.side
      and api._thread_file_path(t.file_path) == want
    then
      local lnum = math.max(math.min(t.line, count), 1)
      if not by_line[lnum] then
        by_line[lnum] = {}
        order[#order + 1] = lnum
      end
      table.insert(by_line[lnum], t)
    end
  end
  table.sort(order)

  for _, lnum in ipairs(order) do
    local group = by_line[lnum]
    local open = false
    local ids = {}
    for _, t in ipairs(group) do
      open = open or is_open(t.status)
      ids[#ids + 1] = t.id
    end
    local text = M.hint(group[1], HINT_WIDTH)
    if #group > 1 then
      text = text .. ' [+' .. (#group - 1) .. ' threads]'
    end
    local ok_mark, mark_id = pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, lnum - 1, 0, {
      sign_text = open and icons.thread_active or icons.thread_resolved,
      sign_hl_group = open and 'AzurePRThreadActive' or 'AzurePRInlineResolved',
      virt_text = { { '  ' .. text, open and 'AzurePRInlineHint' or 'AzurePRInlineResolved' } },
      virt_text_pos = 'eol',
    })
    st.marks[#st.marks + 1] = { id = ok_mark and mark_id or nil, lnum = lnum, thread_ids = ids, threads = group }
  end

  vim.b[buf].azure_pr_inline = { pr_id = pr and pr.id, side = opts.side, path = opts.path }
  set_keys(buf, st)
  M._ensure_refresh_autocmd()
end

local refresh_registered = false

--- Re-place markers in every buffer attached to the PR whose threads changed in the store.
function M._ensure_refresh_autocmd()
  if refresh_registered then
    return
  end
  refresh_registered = true
  vim.api.nvim_create_autocmd('User', {
    group = vim.api.nvim_create_augroup('AzurePRInlineRefresh', { clear = true }),
    pattern = 'AzurePRThreadsChanged',
    callback = function(ev)
      local pr_id = ev.data and ev.data.pr_id
      local entry = pr_id ~= nil and require('azure_pr.threads_store').get(pr_id) or nil
      if not entry then
        return
      end
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local ok, info = pcall(function()
          return vim.b[buf].azure_pr_inline
        end)
        if ok and type(info) == 'table' and tostring(info.pr_id) == tostring(pr_id) and state[buf] then
          M.place(buf, entry.pr, entry.threads, { side = info.side, path = info.path })
        end
      end
    end,
  })
end

local function inline_keys()
  local defaults = { reply = 'r', status = 's', browser = 'o', close = { 'q', '<Esc>' } }
  local ok, config = pcall(require, 'azure_pr.config')
  if not ok then
    return defaults
  end
  local okc, cur = pcall(config.get)
  local user = okc and type(cur) == 'table' and cur.keymaps and cur.keymaps.inline or {}
  return vim.tbl_extend('force', defaults, user)
end

--- Float with the full thread(s) on `lnum` of `buf` (defaults: current buffer / cursor line).
---@param buf integer|nil
---@param lnum integer|nil
function M.show_thread(buf, lnum)
  buf = buf or vim.api.nvim_get_current_buf()
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local threads = M.threads_at(buf, lnum)
  if #threads == 0 then
    vim.notify('No comment thread on this line', vim.log.levels.WARN)
    return
  end
  local info = vim.b[buf].azure_pr_inline or {}
  local entry = info.pr_id ~= nil and require('azure_pr.threads_store').get(info.pr_id) or nil
  local pst = state[buf]
  local pr = (entry and entry.pr) or (pst and pst.pr) or { id = info.pr_id }

  local render = require 'azure_pr.ui.render'
  local width = math.min(80, vim.o.columns - 4)
  local lines, highlights, items = {}, {}, {}
  local total = 0
  for i, t in ipairs(threads) do
    if i > 1 then
      lines[#lines + 1] = ''
    end
    if #threads > 1 then
      lines[#lines + 1] = ('[%s] thread %d/%d%s'):format(t.status or 'unknown', i, #threads, t.id ~= nil and (' #' .. tostring(t.id)) or '')
      items[#lines] = { kind = 'thread', thread = t }
      highlights[#highlights + 1] = { #lines - 1, 0, -1, is_open(t.status) and 'AzurePRThreadActive' or 'AzurePRInlineResolved' }
    end
    local res = render.thread_lines(t, { width = width, icons = hl.icons(use_icons()), pr = pr })
    local off = #lines
    for _, l in ipairs(res.lines) do
      lines[#lines + 1] = l
    end
    for _, h in ipairs(res.highlights) do
      highlights[#highlights + 1] = { h[1] + off, h[2], h[3], h[4] }
    end
    for n, item in pairs(res.items) do
      items[n + off] = item
    end
    total = total + #visible_text_comments(t)
  end

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].buftype = 'nofile'
  vim.bo[fbuf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  for _, h in ipairs(highlights) do
    pcall(vim.api.nvim_buf_set_extmark, fbuf, M.ns, h[1], h[2], {
      end_row = h[3] == -1 and h[1] + 1 or h[1],
      end_col = h[3] ~= -1 and h[3] or 0,
      hl_group = h[4],
    })
  end
  vim.bo[fbuf].modifiable = false

  local status = #threads == 1 and (threads[1].status or 'unknown') or (#threads .. ' threads')
  if #threads == 1 and threads[1].id ~= nil then
    status = status .. ' #' .. tostring(threads[1].id)
  end
  local title = (' %s · %d comment%s '):format(status, total, total == 1 and '' or 's')
  local win = vim.api.nvim_open_win(fbuf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = math.max(math.min(#lines, 20), 1),
    style = 'minimal',
    border = 'rounded',
    title = title,
    title_pos = 'left',
  })
  vim.wo[win].wrap = true
  -- AzurePRCommentBody links to Normal: keep the float background instead of painting Normal over it
  vim.wo[win].winhighlight = 'NormalFloat:NormalFloat,AzurePRCommentBody:NormalFloat'

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  vim.api.nvim_create_autocmd('WinLeave', { buffer = fbuf, once = true, callback = close })

  local function under_cursor()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local item = items[row]
    -- fall back to the nearest item above (wrapped / blank lines)
    local r = row
    while not item and r > 1 do
      r = r - 1
      item = items[r]
    end
    if not item then
      local low
      for l, it in pairs(items) do
        if not low or l < low then
          low, item = l, it
        end
      end
    end
    local t = item and item.thread or threads[1]
    return t, item and item.kind == 'comment' and item.comment or nil
  end

  local function done(err)
    if not err then
      close()
    end
  end

  local keys = inline_keys()
  local function map(lhss, fn, desc)
    for _, lhs in ipairs(lhs_list(lhss)) do
      vim.keymap.set('n', lhs, fn, { buffer = fbuf, nowait = true, silent = true, desc = 'Azure PR: ' .. desc })
    end
  end
  local actions = require 'azure_pr.actions'
  map(keys.close, close, 'Close thread')
  map(keys.reply, function()
    local t, c = under_cursor()
    actions.reply(pr, t, c, function(err)
      if not err then
        actions.refresh_detail_of(pr)
      end
      done(err)
    end)
  end, 'Reply')
  map(keys.status, function()
    local t = under_cursor()
    actions.set_thread_status(pr, t, function(err)
      if not err then
        actions.refresh_detail_of(pr)
      end
      done(err)
    end)
  end, 'Change thread status')
  map(keys.browser, function()
    actions.open_in_browser(pr)
  end, 'Open PR in browser')
end

--- Current 1-based line of a mark (extmarks move with edits); the place-time line without an extmark.
local function mark_lnum(buf, m)
  if not m.id then
    return m.lnum
  end
  local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, M.ns, m.id, {})
  if not ok or not pos or pos[1] == nil then
    return nil
  end
  return pos[1] + 1
end

--- Threads anchored on `lnum` (1-based).
---@param buf integer
---@param lnum integer
---@return table[]
function M.threads_at(buf, lnum)
  local st = state[buf]
  if not st then
    return {}
  end
  local out = {}
  for _, m in ipairs(st.marks) do
    if mark_lnum(buf, m) == lnum then
      vim.list_extend(out, m.threads)
    end
  end
  return out
end

--- Move the cursor to the next/previous line with a thread (wraps around).
---@param buf integer
---@param dir integer 1|-1
function M.jump(buf, dir)
  local st = state[buf]
  if not st then
    return
  end
  local lines, seen = {}, {}
  for _, m in ipairs(st.marks) do
    local l = mark_lnum(buf, m)
    if l and not seen[l] then
      seen[l] = true
      lines[#lines + 1] = l
    end
  end
  table.sort(lines)
  local n = #lines
  if n == 0 then
    return
  end
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    win = vim.api.nvim_get_current_win()
  end
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local target
  if dir > 0 then
    target = lines[1]
    for _, l in ipairs(lines) do
      if l > cur then
        target = l
        break
      end
    end
  else
    target = lines[n]
    for i = n, 1, -1 do
      if lines[i] < cur then
        target = lines[i]
        break
      end
    end
  end
  vim.api.nvim_win_set_cursor(win, { target, 0 })
end

-- ---------------------------------------------------------------------------
-- Automatic attach (diffview buffers opened by azure_pr, working-tree files of a PR branch).
-- Everything here is silent: no vim.notify, no vim.ui.select, errors are dropped.
-- ---------------------------------------------------------------------------

local GIT_CACHE_TTL = 30 -- seconds

local git_cache = {} ---@type table<string, { root: string, branch: string, t: number }> dir -> repo info
local git_inflight = {} ---@type table<string, function[]> dir -> callbacks waiting for the running lookup
local remote_cache = {} ---@type table<string, table|false> root -> parsed Azure remote (false: none)
local pr_cache = {} ---@type table<string, table> "root\0branch" -> { pr = PR|false } or { waiting = fun[] }
local file_attached = {} ---@type table<integer, { root: string, branch: string, pr_id: any }> buffers marked by attach_file_buf

--- Forget cached git info and PR lookups (tests).
function M._reset_caches()
  git_cache, git_inflight, remote_cache, pr_cache, file_attached = {}, {}, {}, {}, {}
end

--- Expire the cached git branch info only (tests simulate the TTL passing).
function M._reset_caches_git_only()
  git_cache = {}
end

--- Load threads of `pr` (store first, then a silent fetch) and place them in `buf`.
local function place_from_store(buf, pr, opts)
  local store = require 'azure_pr.threads_store'
  local entry = store.get(pr.id)
  if entry then
    return M.place(buf, pr, entry.threads, opts)
  end
  store.fetch(pr, function(err, threads)
    if not err and threads and vim.api.nvim_buf_is_valid(buf) then
      M.place(buf, pr, threads, opts)
    end
  end)
end

--- `User DiffviewDiffBufWinEnter`: mark threads in a diffview buffer of a PR diff opened by azure_pr.
---@param buf integer
function M.attach_diffview_buf(buf)
  local ok_lib, lib = pcall(require, 'diffview.lib')
  if not ok_lib or type(lib.get_current_view) ~= 'function' then
    return
  end
  local ok, view = pcall(lib.get_current_view)
  if not ok or type(view) ~= 'table' then
    return
  end
  local diff = require('azure_pr.state').diff_views[view.tabpage or vim.api.nvim_get_current_tabpage()]
  if not diff or not diff.pr then
    return
  end
  local layout = view.cur_entry and view.cur_entry.layout
  if not layout then
    return
  end
  for _, win in ipairs { layout.a, layout.b } do
    local file = win and win.file
    if file and file.bufnr == buf and file.path then
      local side = file.symbol == 'a' and 'left' or 'right'
      return place_from_store(buf, diff.pr, { side = side, path = file.path })
    end
  end
end

--- Drop diff_views entries whose diffview tab is gone.
function M._prune_diff_views()
  local views = require('azure_pr.state').diff_views
  local ok_lib, lib = pcall(require, 'diffview.lib')
  for tab in pairs(views) do
    local gone = not vim.api.nvim_tabpage_is_valid(tab)
    if not gone and ok_lib and type(lib.tabpage_to_view) == 'function' then
      local okv, v = pcall(lib.tabpage_to_view, tab)
      gone = okv and not v
    end
    if gone then
      views[tab] = nil
    end
  end
end

--- Root and branch of the git repo containing `dir`; `cb(nil)` when there is none (or HEAD is
--- detached). Results, including failures, are cached for GIT_CACHE_TTL seconds and concurrent
--- lookups for one dir share a single git run.
local function repo_info(dir, cb)
  local c = git_cache[dir]
  if c and os.time() - c.t < GIT_CACHE_TTL then
    return cb(c.root, c.branch)
  end
  if git_inflight[dir] then
    table.insert(git_inflight[dir], cb)
    return
  end
  local waiting = { cb }
  git_inflight[dir] = waiting
  local function finish(root, branch)
    git_cache[dir] = { root = root, branch = branch, t = os.time() }
    git_inflight[dir] = nil
    for _, f in ipairs(waiting) do
      f(root, branch)
    end
  end
  local actions = require 'azure_pr.actions'
  actions._git({ 'rev-parse', '--show-toplevel' }, { cwd = dir }, function(code, out)
    local root = vim.trim(out or '')
    if code ~= 0 or root == '' then
      return finish(nil, nil)
    end
    actions._git({ 'rev-parse', '--abbrev-ref', 'HEAD' }, { cwd = dir }, function(bcode, bout)
      local branch = vim.trim(bout or '')
      if bcode ~= 0 or branch == '' or branch == 'HEAD' then
        return finish(nil, nil)
      end
      finish(root, branch)
    end)
  end)
end

--- Azure DevOps `origin` remote of `root` (`cb(remote|nil)`), cached per root for the session.
local function remote_for_root(root, cb)
  local hit = remote_cache[root]
  if hit ~= nil then
    return cb(hit or nil)
  end
  require('azure_pr.actions')._git({ 'remote', 'get-url', 'origin' }, { cwd = root }, function(code, out)
    local remote = code == 0 and require('azure_pr.util').parse_remote(vim.trim(out or '')) or nil
    remote_cache[root] = remote or false
    cb(remote)
  end)
end

--- PR whose source branch is `branch`: an open detail view first, else one silent lookup per session.
local function pr_for_branch(root, branch, cb)
  for _, dst in pairs(require('azure_pr.ui.detail')._states) do
    if dst.pr and dst.pr.source_branch == branch then
      return cb(dst.pr)
    end
  end
  local key = root .. '\0' .. branch
  local hit = pr_cache[key]
  if hit and hit.waiting then
    table.insert(hit.waiting, cb)
    return
  elseif hit then
    return cb(hit.pr or nil)
  end
  local entry = { waiting = { cb } }
  pr_cache[key] = entry
  require('azure_pr.actions').current_branch_pr(function(err, pr)
    local result = (not err and pr) or false
    pr_cache[key] = { pr = result }
    for _, f in ipairs(entry.waiting) do
      f(result or nil)
    end
  end, { cwd = root, silent = true })
end

--- `BufWinEnter` of a regular file: mark PR threads when HEAD is the PR's source branch.
--- Re-resolves on every entry (cached), so markers disappear after a branch switch.
---@param buf integer
function M.attach_file_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or name:find '^%a[%w+.-]*://' then
    return
  end
  local prev = file_attached[buf]
  if state[buf] and not prev then
    return -- marked by someone else (diffview)
  end
  local function drop()
    if prev and file_attached[buf] == prev then
      file_attached[buf] = nil
      M.detach(buf)
    end
  end
  repo_info(vim.fs.dirname(name), function(root, branch)
    if not root then
      return drop()
    end
    local prefix = root:gsub('/+$', '') .. '/'
    if name:sub(1, #prefix) ~= prefix then
      return drop()
    end
    local rel = name:sub(#prefix + 1)
    -- only Azure DevOps repositories, and only when azure_pr resolves a target
    remote_for_root(root, function(remote)
      if not remote then
        return drop()
      end
      require('azure_pr.config').resolve_target(function(terr)
        if terr then
          return drop()
        end
        pr_for_branch(root, branch, function(pr)
          if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_name(buf) ~= name then
            return
          end
          local repo = pr and pr.repository and pr.repository.name
          if not (repo and remote.repository and repo:lower() == remote.repository:lower()) then
            return drop()
          end
          if prev and prev.root == root and prev.branch == branch and prev.pr_id == pr.id and state[buf] then
            return
          end
          file_attached[buf] = { root = root, branch = branch, pr_id = pr.id }
          place_from_store(buf, pr, { side = 'right', path = rel })
        end)
      end)
    end)
  end)
end


--- Register the autocmds (idempotent).
function M.setup()
  local group = vim.api.nvim_create_augroup('AzurePRInline', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'DiffviewDiffBufWinEnter',
    callback = function()
      pcall(M.attach_diffview_buf, vim.api.nvim_get_current_buf())
    end,
  })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'DiffviewViewClosed',
    callback = function()
      vim.schedule(function()
        pcall(M._prune_diff_views)
      end)
    end,
  })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    callback = function(ev)
      pcall(M.attach_file_buf, ev.buf)
    end,
  })
end

return M
