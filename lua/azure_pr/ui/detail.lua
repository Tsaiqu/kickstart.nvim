-- PR detail buffer: header, reviewers, checks, description and comment threads.
--
-- Buffer name `azure-pr://pr/<id>` (a hyphen, not an underscore: Neovim only treats
-- `[A-Za-z0-9+.-]+://` as a URL scheme, see ui/input.lua). One buffer per PR id; reopening
-- the same PR focuses/reuses it and refreshes.
--
-- Mutations (comment/reply/edit/delete/status/vote) go through azure_pr.actions; their callback
-- triggers a refresh of this buffer. Notifications about the mutation result are left to actions.
local M = {}

local NAME_PREFIX = 'azure-pr://pr/'
local FILETYPE = 'azure_pr_detail'

---@type table<integer, table> buf -> view state
M._states = {}
---@type table<string, integer> tostring(pr id) -> buf
M._bufs = {}

local function api()
  return require 'azure_pr.api'
end

local function models()
  return require 'azure_pr.models'
end

local function actions()
  return require 'azure_pr.actions'
end

local function notify(msg, level)
  local ok, util = pcall(require, 'azure_pr.util')
  if ok and util.notify then
    util.notify(msg, level)
  else
    vim.notify(msg, level or vim.log.levels.INFO, { title = 'Azure PR' })
  end
end

local function cfg()
  local ok, config = pcall(require, 'azure_pr.config')
  if ok and type(config.get) == 'function' then
    local ok2, c = pcall(config.get)
    if ok2 and type(c) == 'table' then
      return c
    end
  end
  return {}
end

local function lower(s)
  return s and tostring(s):lower() or nil
end

local function same_id(a, b)
  return a ~= nil and b ~= nil and lower(a) == lower(b)
end

--------------------------------------------------------------------------------
-- Buffer helpers
--------------------------------------------------------------------------------

-- `:bdelete` leaves the buffer valid but unloaded, with its options and keymaps reset.
local function usable(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

local function apply_highlights(buf, lines, highlights)
  local ns = require('azure_pr.ui.highlights').ns
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(highlights or {}) do
    local line, cs, ce, group = h[1], h[2], h[3], h[4]
    local text = lines[line + 1]
    if text then
      if ce == nil or ce < 0 or ce > #text then
        ce = #text
      end
      if cs < ce then
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, cs, { end_row = line, end_col = ce, hl_group = group })
      end
    end
  end
end

local function wins_of(buf)
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then
      out[#out + 1] = w
    end
  end
  return out
end

local function setup_window(win)
  local function wo(name, value)
    pcall(vim.api.nvim_set_option_value, name, value, { scope = 'local', win = win })
  end
  wo('wrap', true)
  wo('linebreak', true)
  wo('cursorline', true)
  wo('number', false)
  wo('relativenumber', false)
  wo('signcolumn', 'no')
  wo('foldcolumn', '0')
  wo('spell', false)
  wo('list', false)
end

--- The item for a line (1-based) or the cursor line of the current window.
---@param buf integer|nil
---@param lnum integer|nil
---@return table|nil
function M.item_at(buf, lnum)
  buf = buf or vim.api.nvim_get_current_buf()
  local st = M._states[buf]
  if not st or not st.items then
    return nil
  end
  if not lnum then
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(win) ~= buf then
      win = wins_of(buf)[1]
      if not win then
        return nil
      end
    end
    lnum = vim.api.nvim_win_get_cursor(win)[1]
  end
  return st.items[lnum]
end

-- Stable anchor describing the item under a cursor line, used to restore the cursor after re-render.
local function anchor_of(item)
  if not item then
    return nil
  end
  if item.kind == 'comment' and item.thread and item.comment then
    return { kind = 'comment', thread_id = item.thread.id, comment_id = item.comment.id }
  elseif item.kind == 'thread' and item.thread then
    return { kind = 'thread', thread_id = item.thread.id }
  elseif item.kind == 'reviewer' and item.reviewer then
    return { kind = 'reviewer', id = item.reviewer.id }
  elseif item.kind == 'meta' then
    return { kind = 'meta', key = item.key }
  elseif item.kind == 'section' then
    return { kind = 'section', section = item.section }
  end
  return nil
end

local function find_anchor(items, a, prefer)
  if not a then
    return nil
  end
  local best, fallback
  for lnum, item in pairs(items) do
    local match = false
    if a.kind == 'comment' and item.kind == 'comment' then
      match = item.thread and item.thread.id == a.thread_id and item.comment and item.comment.id == a.comment_id
    elseif a.kind == 'thread' and item.kind == 'thread' then
      match = item.thread and item.thread.id == a.thread_id
    elseif a.kind == 'reviewer' and item.kind == 'reviewer' then
      match = item.reviewer and item.reviewer.id == a.id
    elseif a.kind == 'meta' and item.kind == 'meta' then
      match = item.key == a.key
    elseif a.kind == 'section' and item.kind == 'section' then
      match = item.section == a.section
    end
    if match then
      -- comments span several lines: keep the same offset into the block when possible
      if prefer and lnum == prefer then
        return lnum
      end
      if not best or lnum < best then
        best = lnum
      end
    end
    -- a comment of a thread that is now folded -> fall back to the thread header
    if a.kind == 'comment' and item.kind == 'thread' and item.thread and item.thread.id == a.thread_id then
      fallback = lnum
    end
  end
  return best or fallback
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

local keymap_config -- defined below (keymaps section)

local function render(buf, opts)
  opts = opts or {}
  local st = M._states[buf]
  if not st or not usable(buf) then
    return
  end
  local km = keymap_config()
  local R = require 'azure_pr.ui.render'
  if not st.pr then
    local lines
    local hls
    local err_text = st.error and (tostring(st.error):gsub('[\r\n]+', ' ')) or nil
    if st.error and st.loading then
      -- retry in flight: say so, keep the last error as a muted hint
      lines = { ' Retrying PR !' .. tostring(st.id or '?') .. '…', '', ' Last error: ' .. err_text }
      hls = { { 0, 0, -1, 'AzurePRMuted' }, { 2, 0, -1, 'AzurePRMuted' } }
    elseif st.error then
      lines = { ' Failed to load PR !' .. tostring(st.id or '?'), '', ' ' .. err_text, '', ' ' .. R.retry_hint(km) }
      hls = { { 0, 0, -1, 'AzurePRRejected' } }
    else
      lines = { ' Loading PR !' .. tostring(st.id or '?') .. '…' }
      hls = { { 0, 0, -1, 'AzurePRMuted' } }
    end
    set_lines(buf, lines)
    apply_highlights(buf, lines, hls)
    st.items = {}
    return
  end

  -- remember cursor anchors for every window showing this buffer
  local saved = {}
  for _, w in ipairs(wins_of(buf)) do
    local cur = vim.api.nvim_win_get_cursor(w)
    local item = st.items and st.items[cur[1]]
    local a = anchor_of(item)
    -- offset inside a multi-line comment block
    local offset = 0
    if a and a.kind == 'comment' then
      local l = cur[1]
      while l > 1 and st.items[l - 1] and st.items[l - 1].comment == item.comment do
        l = l - 1
      end
      offset = cur[1] - l
    end
    saved[w] = { cursor = cur, anchor = opts.anchor or a, offset = offset }
  end

  local res = R.pr_detail(st.pr, st.threads or {}, {
    statuses = st.statuses,
    policies = st.policies,
    user_id = st.user_id,
    show_resolved = st.show_resolved,
    folded = st.folded,
    hints = R.hints('detail', km),
    keymaps = km,
    threads_loading = not st.threads_loaded and not st.threads_error,
    threads_error = st.threads_error,
  })
  set_lines(buf, res.lines)
  apply_highlights(buf, res.lines, res.highlights)
  st.items = res.items
  if st.loading then
    pcall(vim.api.nvim_buf_set_extmark, buf, require('azure_pr.ui.highlights').ns, 0, 0, {
      virt_text = { { '  refreshing…', 'AzurePRMuted' } },
      virt_text_pos = 'eol',
    })
  end

  local n = #res.lines
  for w, s in pairs(saved) do
    if vim.api.nvim_win_is_valid(w) then
      local lnum = find_anchor(res.items, s.anchor)
      if lnum and s.offset > 0 then
        local target = lnum + s.offset
        local base = res.items[lnum]
        if res.items[target] and base and res.items[target].comment == base.comment then
          lnum = target
        end
      end
      lnum = math.max(1, math.min(lnum or s.cursor[1], n))
      local col = lnum == s.cursor[1] and s.cursor[2] or 0
      pcall(vim.api.nvim_win_set_cursor, w, { lnum, col })
    end
  end
end

M._render = render

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

local function repo_id_of(st)
  return st.repository_id or (st.pr and st.pr.repository and st.pr.repository.id)
end

local function project_id_of(st)
  return st.project_id or (st.pr and st.pr.repository and st.pr.repository.project_id)
end

local function finish_pr(raw)
  local pr = models().normalize_pr(raw)
  local ok, url = pcall(api().web_url, pr)
  if ok and url then
    pr.url = url
  end
  return pr
end

--- Fetch everything for the buffer. PR, threads, statuses, policy evaluations and the current user
--- are requested in parallel; statuses/policies failures are tolerated (section simply omitted).
local function load(buf, done)
  local st = M._states[buf]
  if not st then
    return
  end
  st.gen = (st.gen or 0) + 1
  local gen = st.gen
  st.loading = true
  local A = api()
  render(buf) -- 'Loading PR…' or the known data with a 'refreshing…' marker

  local function alive()
    local s = M._states[buf]
    return s == st and s.gen == gen and usable(buf)
  end

  local function fetch_rest(repo_id, project_id, raw_pr_known)
    local pending = 0
    local res = { raw_pr = raw_pr_known }
    local finished = false

    local function check()
      if pending > 0 or finished then
        return
      end
      finished = true
      if not alive() then
        return
      end
      st.loading = false
      if res.pr_err and not st.pr then
        st.error = res.pr_err
        render(buf)
        notify('Failed to load PR !' .. tostring(st.id) .. ': ' .. tostring(res.pr_err), vim.log.levels.ERROR)
        if done then
          done(res.pr_err)
        end
        return
      end
      if res.pr_err then
        notify('Failed to refresh PR !' .. tostring(st.id) .. ': ' .. tostring(res.pr_err), vim.log.levels.ERROR)
      end
      st.error = nil
      if res.raw_pr then
        st.pr = finish_pr(res.raw_pr)
        st.id = st.pr.id or st.id
        local state = require 'azure_pr.state'
        if not state.review_pr or tostring(state.review_pr.id) == tostring(st.pr.id) then
          state.review_pr = st.pr
        end
      end
      if res.threads_err then
        -- keep previously loaded threads (if any); the Threads section shows the error
        st.threads_error = tostring(res.threads_err)
        notify('Failed to load comment threads: ' .. tostring(res.threads_err), vim.log.levels.WARN)
      elseif res.threads then
        st.threads = models().normalize_threads(res.threads, { include_system = st.include_system })
        st.threads_loaded = true
        st.threads_error = nil
      end
      -- tolerated failures: keep previous data (or none) and do not bother the user
      if not res.statuses_err then
        st.statuses = res.statuses or st.statuses
      end
      if not res.policies_err then
        st.policies = res.policies or st.policies
      end
      st.check_errors = { statuses = res.statuses_err, policies = res.policies_err }
      if res.user then
        st.user_id = res.user.id
      end
      render(buf)
      if done then
        done(res.pr_err)
      end
    end

    local function start(fn)
      pending = pending + 1
      local ok, err = pcall(fn)
      if not ok then
        pending = pending - 1
        error(err)
      end
    end

    if not raw_pr_known then
      start(function()
        A.get_pull_request(repo_id, st.id, function(err, raw)
          res.pr_err, res.raw_pr = err, (not err) and raw or nil
          pending = pending - 1
          -- policy evaluations need the project id which may only be known now
          if not err and raw and not project_id then
            local p = raw.repository and raw.repository.project and raw.repository.project.id
            if p then
              pending = pending + 1
              A.list_policy_evaluations(p, st.id, function(perr, list)
                res.policies_err, res.policies = perr, list
                pending = pending - 1
                check()
              end)
            end
          end
          check()
        end)
      end)
    end
    start(function()
      A.list_threads(repo_id, st.id, function(err, list)
        res.threads_err, res.threads = err, list
        pending = pending - 1
        check()
      end)
    end)
    start(function()
      A.list_statuses(repo_id, st.id, function(err, list)
        res.statuses_err, res.statuses = err, list
        pending = pending - 1
        check()
      end)
    end)
    if project_id then
      start(function()
        A.list_policy_evaluations(project_id, st.id, function(err, list)
          res.policies_err, res.policies = err, list
          pending = pending - 1
          check()
        end)
      end)
    end
    local state = require 'azure_pr.state'
    if state.user and state.user.id then
      res.user = state.user
    else
      start(function()
        A.get_current_user(function(err, user)
          if not err and user then
            res.user = user
            state.user = user
          end
          pending = pending - 1
          check()
        end)
      end)
    end
    check()
  end

  local repo_id = repo_id_of(st)
  if repo_id then
    fetch_rest(repo_id, project_id_of(st), nil)
  else
    -- only the PR id is known: resolve it project-wide first
    A.get_pull_request_by_id(st.id, function(err, raw)
      if not alive() then
        return
      end
      if err or not raw then
        st.loading = false
        err = err or 'PR not found'
        if not st.pr then
          st.error = err
          render(buf)
        end
        notify('Failed to load PR !' .. tostring(st.id) .. ': ' .. tostring(err), vim.log.levels.ERROR)
        if done then
          done(err)
        end
        return
      end
      local repo = raw.repository or {}
      st.repository_id = repo.id
      st.project_id = repo.project and repo.project.id or nil
      fetch_rest(repo.id, st.project_id, raw)
    end)
  end
end

--------------------------------------------------------------------------------
-- Actions under cursor
--------------------------------------------------------------------------------

local function current_state()
  local buf = vim.api.nvim_get_current_buf()
  return M._states[buf], buf
end

local function refresher(buf)
  return function(err)
    if err == nil or err == false then
      M.refresh(buf)
    end
  end
end

local function thread_under_cursor(buf)
  local item = M.item_at(buf)
  if item and item.thread then
    return item.thread, item
  end
  return nil, item
end

local function first_comment(thread)
  for _, c in ipairs(thread and thread.comments or {}) do
    if not c.is_deleted then
      return c
    end
  end
  return thread and thread.comments and thread.comments[1] or nil
end

local function own_comment_under_cursor(st, buf, what)
  local item = M.item_at(buf)
  if not item or item.kind ~= 'comment' or not item.comment then
    notify('Place the cursor on a comment to ' .. what .. ' it', vim.log.levels.WARN)
    return nil
  end
  local c = item.comment
  if c.is_deleted then
    notify('Comment is already deleted', vim.log.levels.WARN)
    return nil
  end
  -- ownership is enforced only when the current user is known; the server rejects others anyway
  if st.user_id and not same_id(c.author and c.author.id, st.user_id) then
    notify('You can only ' .. what .. ' your own comments', vim.log.levels.WARN)
    return nil
  end
  return item
end

local handlers = {}

function handlers.comment()
  local st, buf = current_state()
  if st and st.pr then
    actions().comment(st.pr, refresher(buf))
  end
end

function handlers.reply()
  local st, buf = current_state()
  if not st or not st.pr then
    return
  end
  local thread, item = thread_under_cursor(buf)
  if not thread then
    notify('Place the cursor on a comment thread to reply', vim.log.levels.WARN)
    return
  end
  local parent = (item and item.kind == 'comment' and item.comment) or first_comment(thread)
  actions().reply(st.pr, thread, parent, refresher(buf))
end

function handlers.edit()
  local st, buf = current_state()
  if not st or not st.pr then
    return
  end
  local item = own_comment_under_cursor(st, buf, 'edit')
  if item then
    actions().edit_comment(st.pr, item.thread, item.comment, refresher(buf))
  end
end

function handlers.delete()
  local st, buf = current_state()
  if not st or not st.pr then
    return
  end
  local item = own_comment_under_cursor(st, buf, 'delete')
  if item then
    -- confirmation is done by actions.delete_comment (shared with other callers)
    actions().delete_comment(st.pr, item.thread, item.comment, refresher(buf))
  end
end

function handlers.thread_status()
  local st, buf = current_state()
  if not st or not st.pr then
    return
  end
  local thread = thread_under_cursor(buf)
  if not thread then
    notify('Place the cursor on a comment thread to change its status', vim.log.levels.WARN)
    return
  end
  actions().set_thread_status(st.pr, thread, refresher(buf))
end

function handlers.toggle_resolved()
  local st, buf = current_state()
  if not st then
    return
  end
  st.show_resolved = not st.show_resolved
  render(buf)
  notify(st.show_resolved and 'Showing resolved threads' or 'Hiding resolved threads')
end

function handlers.toggle_thread()
  local st, buf = current_state()
  if not st or not st.pr then
    return
  end
  local thread = thread_under_cursor(buf)
  if not thread or thread.id == nil then
    return
  end
  st.folded[thread.id] = not st.folded[thread.id] or nil
  render(buf, { anchor = { kind = 'thread', thread_id = thread.id } })
end

--- Resolve a thread file path (leading '/' stripped) against cwd, then the git root.
local function resolve_file(path)
  local rel = path:gsub('^/+', '')
  if rel == '' then
    return nil, rel
  end
  local candidates = { rel }
  local ok, root = pcall(vim.fs.root, vim.fn.getcwd(), '.git')
  if ok and root then
    candidates[#candidates + 1] = root .. '/' .. rel
  end
  for _, c in ipairs(candidates) do
    if vim.fn.filereadable(c) == 1 then
      return c, rel
    end
  end
  return nil, rel
end

--- Pick a window for opening a source file: a normal-buffer window in this tab other than the detail
--- window, else a new split.
local function file_window(detail_win)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= detail_win and vim.api.nvim_win_get_config(w).relative == '' then
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].buftype == '' then
        return w
      end
    end
  end
  vim.cmd 'leftabove vsplit'
  return vim.api.nvim_get_current_win()
end

function handlers.open_file()
  local st, buf = current_state()
  if not st or not st.pr then
    return
  end
  local thread, item = thread_under_cursor(buf)
  if not thread or not thread.file_path or thread.file_path == '' then
    -- on a general thread header, <CR> folds like za
    if item and item.kind == 'thread' then
      return handlers.toggle_thread()
    end
    return
  end
  local file, rel = resolve_file(thread.file_path)
  if not file then
    notify('File not found in the working directory: ' .. rel, vim.log.levels.WARN)
    return
  end
  local win = file_window(vim.api.nvim_get_current_win())
  vim.api.nvim_set_current_win(win)
  vim.cmd('edit ' .. vim.fn.fnameescape(file))
  -- line comments from this file buffer go to this PR (see actions.comment_on_line)
  require('azure_pr.state').review_pr = st.pr
  pcall(function()
    vim.b.azure_pr_id = st.pr.id
  end)
  if thread.line and thread.side == 'left' then
    -- left-side anchors are line numbers of the base (target) version, e.g. comments on deleted lines
    notify(
      string.format(
        'This thread is on line %d of the base version (%s), not of the working tree: not jumping',
        thread.line,
        st.pr.target_branch or 'target branch'
      ),
      vim.log.levels.WARN
    )
    return
  end
  if thread.line then
    local last = vim.api.nvim_buf_line_count(0)
    pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, math.min(thread.line, last)), 0 })
    vim.cmd 'normal! zz'
    -- the thread's line refers to the PR's source branch; warn when something else is checked out
    local pr = st.pr
    if pr.source_branch then
      pcall(actions()._git, { 'rev-parse', '--abbrev-ref', 'HEAD' }, { cwd = vim.fn.fnamemodify(file, ':h') }, function(code, stdout)
        local head = code == 0 and vim.trim(stdout or '') or ''
        if head ~= '' and head ~= pr.source_branch then
          notify(
            string.format(
              'HEAD is %s, not %s (!%s): line %d may not match the PR (C checks the branch out)',
              head,
              pr.source_branch,
              tostring(pr.id),
              thread.line
            ),
            vim.log.levels.WARN
          )
        end
      end)
    end
  end
end

function handlers.vote()
  local st, buf = current_state()
  if st and st.pr then
    actions().vote(st.pr, refresher(buf))
  end
end

function handlers.browser()
  local st = current_state()
  if st and st.pr then
    actions().open_in_browser(st.pr)
  end
end

function handlers.yank_url()
  local st = current_state()
  if st and st.pr then
    actions().yank_url(st.pr)
  end
end

function handlers.refresh()
  M.refresh(vim.api.nvim_get_current_buf())
end

function handlers.close()
  M.close(vim.api.nvim_get_current_buf())
end

local function jump_thread(dir)
  local st, buf = current_state()
  if not st or not st.items then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local n = vim.api.nvim_buf_line_count(buf)
  local l = cur + dir
  while l >= 1 and l <= n do
    local it = st.items[l]
    if it and it.kind == 'thread' then
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      return
    end
    l = l + dir
  end
  notify(dir > 0 and 'No next thread' or 'No previous thread', vim.log.levels.INFO)
end

function handlers.next_thread()
  jump_thread(1)
end

function handlers.prev_thread()
  jump_thread(-1)
end

-- key name -> description (also the order shown in the help float)
local KEY_DESCS = {
  { 'comment', 'New general comment' },
  { 'reply', 'Reply to thread / comment under cursor' },
  { 'edit', 'Edit own comment' },
  { 'delete', 'Delete own comment' },
  { 'thread_status', 'Change thread status' },
  { 'toggle_resolved', 'Show / hide resolved threads' },
  { 'toggle_thread', 'Fold / unfold thread' },
  { 'open_file', 'Open file at thread line' },
  { 'next_thread', 'Next thread' },
  { 'prev_thread', 'Previous thread' },
  { 'vote', 'Vote on PR' },
  { 'browser', 'Open in browser' },
  { 'yank_url', 'Yank PR URL' },
  { 'refresh', 'Refresh' },
  { 'help', 'This help' },
  { 'close', 'Close' },
}

local function lhs_list(v)
  if v == nil or v == false or v == '' then
    return {}
  end
  if type(v) == 'string' then
    return { v }
  end
  return v
end

function keymap_config()
  local defaults = {}
  local ok, config = pcall(require, 'azure_pr.config')
  if ok and config.defaults and config.defaults.keymaps then
    defaults = config.defaults.keymaps.detail or {}
  end
  local c = cfg()
  local user = c.keymaps and c.keymaps.detail or {}
  return vim.tbl_extend('force', defaults, user)
end

function handlers.help()
  local km = keymap_config()
  local rows, kw = {}, 0
  for _, d in ipairs(KEY_DESCS) do
    local keys = table.concat(lhs_list(km[d[1]]), ' / ')
    if keys ~= '' then
      rows[#rows + 1] = { keys, d[2] }
      kw = math.max(kw, vim.fn.strdisplaywidth(keys))
    end
  end
  local lines = {}
  for _, r in ipairs(rows) do
    lines[#lines + 1] = ' ' .. r[1] .. string.rep(' ', kw - vim.fn.strdisplaywidth(r[1])) .. '  ' .. r[2] .. ' '
  end
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local hbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, lines)
  vim.bo[hbuf].modifiable = false
  vim.bo[hbuf].bufhidden = 'wipe'
  local ns = require('azure_pr.ui.highlights').ns
  for i = 1, #lines do
    pcall(vim.api.nvim_buf_set_extmark, hbuf, ns, i - 1, 1, { end_row = i - 1, end_col = 1 + kw, hl_group = 'AzurePRKey' })
  end
  local win = vim.api.nvim_open_win(hbuf, true, {
    relative = 'editor',
    width = math.min(width, math.max(20, vim.o.columns - 4)),
    height = math.min(#lines, math.max(1, vim.o.lines - 4)),
    row = math.max(0, math.floor((vim.o.lines - #lines) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = 'minimal',
    border = 'rounded',
    title = ' Azure PR detail — keys ',
    title_pos = 'center',
  })
  for _, k in ipairs { 'q', '<Esc>', '?' } do
    vim.keymap.set('n', k, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = hbuf, nowait = true, silent = true })
  end
  vim.api.nvim_create_autocmd('BufLeave', {
    buffer = hbuf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_win_close, win, true)
    end,
  })
  return win
end

M._handlers = handlers

local function set_keymaps(buf)
  local km = keymap_config()
  for _, d in ipairs(KEY_DESCS) do
    local name = d[1]
    for _, lhs in ipairs(lhs_list(km[name])) do
      vim.keymap.set('n', lhs, handlers[name], { buffer = buf, nowait = true, silent = true, desc = 'Azure PR: ' .. d[2] })
    end
  end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

local function create_buffer(id)
  local buf = vim.api.nvim_create_buf(false, true)
  local name = NAME_PREFIX .. tostring(id)
  if not pcall(vim.api.nvim_buf_set_name, buf, name) then
    -- a stale buffer with this name exists (e.g. wiped state): add a suffix
    pcall(vim.api.nvim_buf_set_name, buf, name .. '#' .. buf)
  end
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = FILETYPE
  set_keymaps(buf)
  -- BufUnload also covers `:bdelete` of this unlisted buffer (BufDelete does not fire for it); the
  -- unloaded buffer lost its options/keymaps, so drop the state and wipe it (reopen makes a new one).
  -- `:e`/`:e!` also fires BufUnload, but then BufReadCmd right away: the state is restored there.
  local unloaded_state
  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete', 'BufUnload' }, {
    buffer = buf,
    callback = function(ev)
      unloaded_state = M._states[buf] or unloaded_state
      M._states[buf] = nil
      if M._bufs[tostring(id)] == buf then
        M._bufs[tostring(id)] = nil
      end
      if ev.event == 'BufWipeout' then
        unloaded_state = nil
        return true -- delete this autocmd
      end
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) and not vim.api.nvim_buf_is_loaded(buf) then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd('BufReadCmd', {
    buffer = buf,
    callback = function()
      local st = unloaded_state
      unloaded_state = nil
      if not st or M._states[buf] then
        return
      end
      M._states[buf] = st
      if M._bufs[tostring(id)] == nil then
        M._bufs[tostring(id)] = buf
      end
      vim.bo[buf].modifiable = false
      vim.bo[buf].modified = false
      render(buf)
      load(buf)
    end,
  })
  return buf
end

--- Show buf: focus a window already showing it; from the PR list open (or reuse) a vertical split on
--- the right; otherwise use the current window.
local function show(buf, opts)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == buf then
      vim.api.nvim_set_current_win(w)
      return w
    end
  end
  local cur = vim.api.nvim_get_current_win()
  local from_list = opts.split == 'vsplit' or (opts.split == nil and vim.bo[vim.api.nvim_win_get_buf(cur)].filetype == 'azure_pr_list')
  if from_list then
    -- reuse an existing detail window in this tab (another PR) instead of stacking splits
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= cur and vim.bo[vim.api.nvim_win_get_buf(w)].filetype == FILETYPE then
        vim.api.nvim_set_current_win(w)
        vim.api.nvim_win_set_buf(w, buf)
        setup_window(w)
        return w
      end
    end
    vim.cmd 'rightbelow vsplit'
  end
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  setup_window(win)
  return win
end

--- Open the detail view of a PR.
---@param pr_or_ref table normalized AzurePR, raw Azure PR, `{ repository_id, id }` or `{ id }` (project-level lookup)
---@param opts table|nil { split = 'vsplit'|'current'|nil (nil = vsplit when called from the PR list) }
---@return integer|nil buf
function M.open(pr_or_ref, opts)
  opts = opts or {}
  if type(pr_or_ref) ~= 'table' then
    pr_or_ref = { id = tonumber(pr_or_ref) or pr_or_ref }
  end
  local pr, repository_id, project_id
  if pr_or_ref.pullRequestId then -- raw Azure JSON
    pr = finish_pr(pr_or_ref)
  elseif pr_or_ref.repository and type(pr_or_ref.repository) == 'table' and pr_or_ref.title ~= nil then
    pr = pr_or_ref
  end
  local id = pr and pr.id or pr_or_ref.id or pr_or_ref.pr_id
  if id == nil then
    notify('No pull request id given', vim.log.levels.ERROR)
    return nil
  end
  if pr then
    repository_id = pr.repository and pr.repository.id
    project_id = pr.repository and pr.repository.project_id
    if not pr.url then
      local ok, url = pcall(api().web_url, pr)
      if ok then
        pr.url = url
      end
    end
  else
    repository_id = pr_or_ref.repository_id
    project_id = pr_or_ref.project_id
  end

  local key = tostring(id)
  local buf = M._bufs[key]
  local st = buf and M._states[buf]
  if not (usable(buf) and st and vim.bo[buf].filetype == FILETYPE) then
    if buf and vim.api.nvim_buf_is_valid(buf) then
      M._states[buf] = nil
      pcall(vim.api.nvim_buf_delete, buf, { force = true }) -- stale (unloaded) buffer
    end
    buf = create_buffer(id)
    st = { id = id, show_resolved = true, folded = {}, threads = {}, items = {} }
    M._states[buf] = st
    M._bufs[key] = buf
  end
  st.repository_id = repository_id or st.repository_id
  st.project_id = project_id or st.project_id
  local state = require 'azure_pr.state'
  if pr then
    st.pr = pr -- show what we have immediately; refreshed by load()
    state.review_pr = pr
  end
  if state.user and state.user.id then
    st.user_id = state.user.id
  end

  show(buf, opts)
  load(buf) -- renders immediately

  return buf
end

--- Re-fetch and re-render (cursor position is kept on the same item).
---@param buf integer|nil defaults to the current buffer (or the only detail buffer)
---@param done fun(err: string|nil)|nil
function M.refresh(buf, done)
  buf = buf or vim.api.nvim_get_current_buf()
  if not M._states[buf] then
    -- called from elsewhere (e.g. :AzurePR refresh): refresh every open detail buffer
    for b in pairs(M._states) do
      M.refresh(b)
    end
    return
  end
  load(buf, done)
end

--- Close the detail window (or the buffer if it is the last window).
---@param buf integer|nil
function M.close(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local wins = wins_of(buf)
  for _, w in ipairs(wins) do
    local tab_wins = vim.tbl_filter(function(x)
      return vim.api.nvim_win_get_config(x).relative == ''
    end, vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(w)))
    if #tab_wins > 1 then
      pcall(vim.api.nvim_win_close, w, false)
    end
  end
  if vim.api.nvim_buf_is_valid(buf) and #wins_of(buf) > 0 then
    -- last window: drop the buffer (Neovim shows another/empty buffer)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

--- PR shown by an open detail buffer with this id (nil when none is open / not loaded yet).
---@param id integer|string
---@return AzurePR|nil pr, integer|nil buf
function M.find_pr(id)
  local buf = M._bufs[tostring(id)]
  local st = buf and M._states[buf]
  if st and st.pr and vim.api.nvim_buf_is_valid(buf) then
    return st.pr, buf
  end
end

--- View state of a detail buffer (for tests / other modules).
function M.get_state(buf)
  return M._states[buf or vim.api.nvim_get_current_buf()]
end

return M
