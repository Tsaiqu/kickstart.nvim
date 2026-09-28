-- PR list buffer: fetch, filter, group and render Azure DevOps pull requests.
--
-- Buffer name is `azure-pr://prs` (not `azure_pr://` as in the spec: Neovim only treats
-- `[A-Za-z0-9+.-]+://` as a URL scheme, an underscore makes it a cwd-relative file path).
local api = require 'azure_pr.api'
local config = require 'azure_pr.config'
local filter = require 'azure_pr.filter'
local highlights = require 'azure_pr.ui.highlights'
local models = require 'azure_pr.models'
local render = require 'azure_pr.ui.render'
local state = require 'azure_pr.state'
local util = require 'azure_pr.util'

local M = {}

M.BUF_NAME = 'azure-pr://prs'
M.STATUSES = { 'active', 'completed', 'abandoned', 'all' }

-- View state of the (single) list buffer.
local view = {
  buf = nil, ---@type integer|nil
  items = {}, -- [lnum1] = item (from render)
  loading = false,
  error = nil, ---@type string|nil last fetch error
  seq = 0, -- fetch generation; stale responses are ignored
  loaded = false, -- at least one successful fetch for the current status
  truncated = false, -- last fetch hit config.max_prs
  scope = nil, ---@type string|nil server-side scope of the loaded PRs: nil (all) | 'creator' | 'reviewer'
}

--- Server-side narrowing implied by the "me" filters (so max_prs does not hide relevant PRs).
---@param f AzurePRFilters|nil
---@return string|nil
local function scope_of(f)
  f = f or {}
  if f.created_by_me then
    return 'creator'
  elseif f.needs_my_vote or f.reviewer_is_me then
    return 'reviewer'
  end
  return nil
end
M._scope_of = scope_of

local function notify(msg, level)
  util.notify(msg, level or vim.log.levels.INFO)
end

-- A buffer that was `:bdelete`d is still valid but unloaded (options & keymaps reset): treat it as gone.
local function valid_buf()
  return view.buf and vim.api.nvim_buf_is_valid(view.buf) and vim.api.nvim_buf_is_loaded(view.buf) and view.buf or nil
end

--- Windows (any tab) currently showing the list buffer.
local function list_wins()
  local buf = valid_buf()
  if not buf then
    return {}
  end
  return vim.fn.win_findbuf(buf)
end

local function list_win()
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(cur) == view.buf then
    return cur
  end
  return list_wins()[1]
end

local function user_id()
  return state.user and state.user.id or nil
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

--- Item under the cursor (or at `lnum`), or nil.
---@param lnum integer|nil 1-based line; default cursor line of the list window
---@return table|nil
function M.item_at(lnum)
  if not lnum then
    local win = list_win()
    if not win then
      return nil
    end
    lnum = vim.api.nvim_win_get_cursor(win)[1]
  end
  return view.items[lnum]
end

--- PR under the cursor (nil on group/header lines).
---@return AzurePR|nil
function M.pr_at_cursor()
  local item = M.item_at()
  return item and item.kind == 'pr' and item.pr or nil
end

local function set_lines(buf, lines, hls)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, highlights.ns, 0, -1)
  for _, h in ipairs(hls or {}) do
    local line = lines[h[1] + 1]
    if line then
      local end_col = (h[3] == -1 or h[3] > #line) and #line or h[3]
      if end_col > h[2] then
        pcall(vim.api.nvim_buf_set_extmark, buf, highlights.ns, h[1], h[2], { end_col = end_col, hl_group = h[4] })
      end
    end
  end
end

--- Remember what the cursor is on so it can be restored after re-rendering.
local function cursor_anchor(win)
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local item = view.items[lnum]
  return {
    lnum = lnum,
    pr_id = item and item.kind == 'pr' and item.pr and item.pr.id or nil,
    group_key = item and item.group_key,
    kind = item and item.kind,
  }
end

local function restore_cursor(win, anchor, line_count)
  local target
  if anchor.pr_id then
    for lnum, item in pairs(view.items) do
      if item.kind == 'pr' and item.pr and item.pr.id == anchor.pr_id then
        target = lnum
        break
      end
    end
  end
  if not target and anchor.group_key ~= nil then
    for lnum, item in pairs(view.items) do
      if item.kind == 'group' and item.group_key == anchor.group_key then
        target = lnum
        break
      end
    end
  end
  if not target and (anchor.kind == nil or anchor.kind == 'header' or anchor.kind == 'hint') then
    -- fresh view (or cursor on the header): jump to the first PR / group line
    local first
    for lnum, item in pairs(view.items) do
      if (item.kind == 'pr' or item.kind == 'group') and (not first or lnum < first) then
        first = lnum
      end
    end
    target = first
  end
  target = math.max(1, math.min(target or anchor.lnum, line_count))
  pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
end

local function loading_header(status)
  return { ' Azure DevOps PRs  [' .. status .. ']' }
end

--- Build the lines for the current state (no buffer IO).
---@param width integer|nil
---@return table { lines, highlights, items }
function M.build(width)
  local status = state.status or config.get().default_status or 'active'
  if not view.loaded then
    local lines = loading_header(status)
    local hls = { { 0, 0, -1, 'AzurePRHeader' } }
    lines[2] = ''
    if view.error and view.loading then
      -- retry in flight: the old error stays visible as a muted hint
      lines[3] = '  Retrying…'
      lines[4] = ''
      lines[5] = '  Last error: ' .. (view.error:gsub('[\r\n]+', ' '))
      hls[#hls + 1] = { 2, 0, -1, 'AzurePRMuted' }
      hls[#hls + 1] = { 4, 0, -1, 'AzurePRMuted' }
    elseif view.error then
      lines[3] = '  Error: ' .. (view.error:gsub('[\r\n]+', ' '))
      lines[4] = ''
      lines[5] = '  ' .. render.retry_hint((config.get().keymaps or {}).list)
      hls[#hls + 1] = { 2, 0, -1, 'AzurePRRejected' }
      hls[#hls + 1] = { 4, 0, -1, 'AzurePRMuted' }
    else
      lines[3] = '  Loading…'
      hls[#hls + 1] = { 2, 0, -1, 'AzurePRMuted' }
    end
    return { lines = lines, highlights = hls, items = {} }
  end
  local ctx = { user_id = user_id() }
  local prs = filter.apply(state.prs or {}, state.filters or {}, ctx)
  local groups = filter.group(prs, state.group_by, ctx)
  return render.pr_list(groups, {
    collapsed = state.collapsed or {},
    filters_desc = filter.describe(state.filters or {}),
    group_by = state.group_by,
    status = status,
    total = #(state.prs or {}),
    truncated = view.truncated,
    width = width,
    hints = render.hints('list', (config.get().keymaps or {}).list),
  })
end

--- Re-render the list buffer from state (no fetching). Keeps the cursor on the same PR.
function M.render()
  local buf = valid_buf()
  if not buf then
    return
  end
  local win = list_win()
  local anchor = win and cursor_anchor(win)
  local width
  if win then
    -- text area only: subtract number/sign/fold columns (the window may have them after :buffer)
    local info = vim.fn.getwininfo(win)[1]
    width = vim.api.nvim_win_get_width(win) - (info and info.textoff or 0) - 1
  end
  local res = M.build(width)
  view.items = res.items or {}
  set_lines(buf, res.lines, res.highlights)
  if view.loading and view.loaded then
    pcall(vim.api.nvim_buf_set_extmark, buf, highlights.ns, 0, 0, {
      virt_text = { { '  refreshing…', 'AzurePRMuted' } },
      virt_text_pos = 'eol',
    })
  elseif view.loaded and view.error then
    -- a refresh failed after an earlier success: the PRs shown are stale
    local keys = (config.get().keymaps or {}).list
    pcall(vim.api.nvim_buf_set_extmark, buf, highlights.ns, 0, 0, {
      virt_text = {
        { '  refresh failed: ' .. util.truncate((view.error:gsub('[\r\n]+', ' ')), 80) .. ' – ' .. render.retry_hint(keys), 'AzurePRRejected' },
      },
      virt_text_pos = 'eol',
    })
  end
  -- restore cursor in every window showing the list (the current one keeps its anchor)
  for _, w in ipairs(list_wins()) do
    if w == win and anchor then
      restore_cursor(w, anchor, #res.lines)
    else
      local lnum = vim.api.nvim_win_get_cursor(w)[1]
      pcall(vim.api.nvim_win_set_cursor, w, { math.min(lnum, #res.lines), 0 })
    end
  end
end

--------------------------------------------------------------------------------
-- Fetching
--------------------------------------------------------------------------------

--- Fetch current user + PRs for `state.status`, normalize, store in state and re-render.
---@param cb fun(err: string|nil)|nil called after the list was updated
function M.fetch(cb)
  local status = state.status or config.get().default_status or 'active'
  state.status = status
  view.seq = view.seq + 1
  local seq = view.seq
  view.loading = true
  M.render()

  local pending = 2
  local list_err, raws, user_err, info
  local scope = scope_of(state.filters)
  local requested = scope -- `scope` may fall back to nil below when the user is unknown
  local function done()
    pending = pending - 1
    if pending > 0 or seq ~= view.seq then
      return
    end
    view.loading = false
    if user_err and not list_err then
      -- non fatal: "me" filters just match nothing
      notify('Could not determine current user: ' .. user_err, vim.log.levels.WARN)
    end
    if list_err then
      view.error = list_err
      notify('Failed to load pull requests: ' .. list_err, vim.log.levels.ERROR)
    else
      view.error = nil
      local prs = models.normalize_prs(raws or {})
      for _, pr in ipairs(prs) do
        pr.url = pr.url or api.web_url(pr)
      end
      state.prs = prs
      view.loaded = true
      view.truncated = info and info.truncated or false
      view.scope = scope
      -- the "me" filters changed while this fetch was in flight (refetch_if_scope_changed skips
      -- while loading): fetch again for the scope the filters need now, handing the callback on
      local want = scope_of(state.filters)
      if want ~= requested and want ~= view.scope and (view.scope ~= nil or view.truncated) then
        return M.fetch(cb)
      end
    end
    M.render()
    if cb then
      cb(list_err)
    end
  end

  local function list(uid)
    local params = { status = status }
    if scope == 'creator' then
      params.creator_id = uid
    elseif scope == 'reviewer' then
      params.reviewer_id = uid
    end
    if scope and not uid then
      scope = nil -- user unknown: fall back to the full list (the "me" filters then match nothing)
    end
    api.list_pull_requests(params, function(err, result, i)
      if seq ~= view.seq then
        return
      end
      list_err, raws, info = err, result, i
      done()
    end)
  end

  -- a scoped fetch needs the user id first; otherwise both requests run in parallel
  local known = state.user and state.user.id
  if not scope or known then
    list(known)
  end
  api.get_current_user(function(err, user)
    if seq ~= view.seq then
      return
    end
    if user then
      state.user = user
    elseif err and not state.user then
      user_err = err -- reported in done() unless the list failed too (same root cause)
    end
    if scope and not known then
      list(state.user and state.user.id)
    end
    done()
  end)
end

--- Refetch the list (public). Works even when the list buffer is not open (updates state only).
---@param cb fun(err: string|nil)|nil
function M.refresh(cb)
  M.fetch(cb)
end

--------------------------------------------------------------------------------
-- Interactive changes
--------------------------------------------------------------------------------

--- Refetch when the loaded PRs cannot answer the current filters: they were fetched with another
--- server-side scope, or the full list was cut at max_prs and a narrower scope is now wanted.
local function refetch_if_scope_changed()
  if not view.loaded or view.loading then
    return
  end
  local want = scope_of(state.filters)
  if want == view.scope then
    return
  end
  if view.scope == nil and not view.truncated then
    return -- complete list: client-side filtering is exact
  end
  M.fetch()
end
M._refetch_if_scope_changed = refetch_if_scope_changed

local function set_filter(key, value)
  state.filters = state.filters or {}
  if value == '' or value == false then
    value = nil
  end
  state.filters[key] = value
  M.render()
  refetch_if_scope_changed()
end

local function toggle_filter(key)
  state.filters = state.filters or {}
  set_filter(key, not state.filters[key])
end

function M.toggle_group(item)
  item = item or M.item_at()
  if not item or item.group_key == nil then
    return
  end
  state.collapsed = state.collapsed or {}
  local key = item.group_key
  state.collapsed[key] = not state.collapsed[key] or nil
  M.render()
  -- keep the cursor on the group header after folding from a PR line
  local win = list_win()
  if win then
    for lnum, it in pairs(view.items) do
      if it.kind == 'group' and it.group_key == key then
        if state.collapsed[key] then
          pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
        end
        break
      end
    end
  end
end

function M.text_filter()
  vim.ui.input({ prompt = 'Filter PRs: ', default = (state.filters or {}).text or '' }, function(input)
    if input == nil then
      return
    end
    set_filter('text', vim.trim(input))
  end)
end

function M.clear_filters()
  state.filters = {}
  M.render()
  refetch_if_scope_changed()
end

--- Distinct values of `get(pr)` across the fetched PRs, sorted case-insensitively.
local function distinct(get)
  local seen, out = {}, {}
  for _, pr in ipairs(state.prs or {}) do
    local v = get(pr)
    if v and v ~= '' and not seen[v] then
      seen[v] = true
      out[#out + 1] = v
    end
  end
  table.sort(out, function(a, b)
    return a:lower() < b:lower()
  end)
  return out
end

local ANY = '(any)'
local CUSTOM = 'Type a value…'

--- Pick a string filter value from the values present in the list (or type one).
local function pick_value(key, label, get)
  local choices = { ANY }
  vim.list_extend(choices, distinct(get))
  choices[#choices + 1] = CUSTOM
  vim.ui.select(choices, { prompt = label }, function(choice)
    if not choice then
      return
    elseif choice == ANY then
      set_filter(key, nil)
    elseif choice == CUSTOM then
      vim.ui.input({ prompt = label .. ' contains (=value for exact): ', default = (state.filters or {})[key] or '' }, function(input)
        if input ~= nil then
          set_filter(key, vim.trim(input))
        end
      end)
    else
      -- picked from the list: exact (case-insensitive) match, see filter.lua ('=' prefix)
      set_filter(key, '=' .. choice)
    end
  end)
end

local function on_off(v)
  return v and '[x]' or '[ ]'
end

function M.filter_menu()
  local f = state.filters or {}
  local draft_desc = f.draft == nil and 'any' or (f.draft and 'drafts only' or 'non-drafts only')
  local entries = {
    {
      label = 'Author: ' .. (f.author or ANY),
      run = function()
        pick_value('author', 'Author', function(pr)
          return pr.author and pr.author.name
        end)
      end,
    },
    {
      label = 'Repository: ' .. (f.repository or ANY),
      run = function()
        pick_value('repository', 'Repository', function(pr)
          return pr.repository and pr.repository.name
        end)
      end,
    },
    {
      label = 'Target branch: ' .. (f.target_branch or ANY),
      run = function()
        pick_value('target_branch', 'Target branch', function(pr)
          return pr.target_branch
        end)
      end,
    },
    {
      label = 'Draft: ' .. draft_desc,
      run = function()
        local opts = { 'any', 'drafts only', 'non-drafts only' }
        vim.ui.select(opts, { prompt = 'Draft' }, function(choice)
          if choice == 'any' then
            set_filter('draft', nil)
          elseif choice == 'drafts only' then
            set_filter('draft', true)
          elseif choice == 'non-drafts only' then
            -- false is meaningful here (non-drafts only), so bypass set_filter's false->nil
            state.filters = state.filters or {}
            state.filters.draft = false
            M.render()
          end
        end)
      end,
    },
    {
      label = on_off(f.created_by_me) .. ' Created by me',
      run = function()
        toggle_filter 'created_by_me'
      end,
    },
    {
      label = on_off(f.reviewer_is_me) .. " I'm a reviewer",
      run = function()
        toggle_filter 'reviewer_is_me'
      end,
    },
    {
      label = on_off(f.needs_my_vote) .. ' Needs my vote',
      run = function()
        toggle_filter 'needs_my_vote'
      end,
    },
    {
      label = 'Review state: ' .. (f.review_state and (filter.REVIEW_STATE_LABELS[f.review_state] or f.review_state) or ANY),
      run = function()
        local choices = { ANY }
        vim.list_extend(choices, models.REVIEW_STATES)
        vim.ui.select(choices, {
          prompt = 'Review state',
          format_item = function(s)
            return filter.REVIEW_STATE_LABELS[s] or s
          end,
        }, function(choice)
          if choice then
            set_filter('review_state', choice ~= ANY and choice or nil)
          end
        end)
      end,
    },
    { label = 'Clear all filters', run = M.clear_filters },
  }
  vim.ui.select(entries, {
    prompt = 'Filter PRs',
    format_item = function(e)
      return e.label
    end,
  }, function(choice)
    if choice then
      choice.run()
    end
  end)
end

function M.choose_group_by()
  vim.ui.select(filter.GROUP_BY, {
    prompt = 'Group PRs by',
    format_item = function(g)
      return (g == state.group_by and '* ' or '  ') .. g
    end,
  }, function(choice)
    if choice and choice ~= state.group_by then
      state.group_by = choice
      state.collapsed = {} -- group keys are grouping specific
      M.render()
    end
  end)
end

function M.choose_status()
  vim.ui.select(M.STATUSES, {
    prompt = 'PR status',
    format_item = function(s)
      return (s == state.status and '* ' or '  ') .. s
    end,
  }, function(choice)
    if choice and choice ~= state.status then
      state.status = choice
      view.loaded = false -- the cached list is for another status: show "Loading…"
      M.fetch()
    end
  end)
end

--- Re-render an open detail view of `pr` after a comment/vote from the list.
local function refresh_detail_of(pr)
  local ok, actions = pcall(require, 'azure_pr.actions')
  if ok and type(actions.refresh_detail_of) == 'function' then
    pcall(actions.refresh_detail_of, pr)
  end
end

--- Call `azure_pr.actions.<name>(pr, ...)` for the PR under the cursor.
local function with_action(name, ...)
  local pr = M.pr_at_cursor()
  if not pr then
    notify('No pull request under cursor', vim.log.levels.WARN)
    return
  end
  local ok, actions = pcall(require, 'azure_pr.actions')
  if not ok or type(actions[name]) ~= 'function' then
    notify('azure_pr.actions.' .. name .. ' is not available', vim.log.levels.ERROR)
    return
  end
  actions[name](pr, ...)
end

function M.open_under_cursor()
  local item = M.item_at()
  if not item then
    return
  end
  if item.kind == 'group' then
    return M.toggle_group(item)
  elseif item.kind == 'pr' and item.pr then
    local ok, detail = pcall(require, 'azure_pr.ui.detail')
    if not ok then
      return notify('PR detail view is not available: ' .. tostring(detail), vim.log.levels.ERROR)
    end
    detail.open(item.pr)
  end
end

function M.close()
  local win = list_win()
  if not win then
    return
  end
  local tab_wins = vim.tbl_filter(function(w)
    return vim.api.nvim_win_get_config(w).relative == ''
  end, vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win)))
  if #tab_wins > 1 then
    vim.api.nvim_win_close(win, false)
  elseif #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd 'tabclose'
  else
    -- last window: show the alternate buffer or an empty one
    local alt = vim.fn.bufnr '#'
    if alt > 0 and alt ~= view.buf and vim.api.nvim_buf_is_valid(alt) and vim.bo[alt].buflisted then
      vim.api.nvim_win_set_buf(win, alt)
    else
      vim.cmd 'enew'
    end
  end
end

--------------------------------------------------------------------------------
-- Keymaps & help
--------------------------------------------------------------------------------

-- Order = order in help. Handlers are looked up lazily so tests can stub M.* functions.
M.KEYMAP_ACTIONS = {
  {
    'open',
    'Open PR / toggle group',
    function()
      M.open_under_cursor()
    end,
  },
  {
    'toggle_group',
    'Toggle group fold',
    function()
      M.toggle_group()
    end,
  },
  {
    'refresh',
    'Refresh',
    function()
      M.refresh()
    end,
  },
  {
    'text_filter',
    'Edit text filter',
    function()
      M.text_filter()
    end,
  },
  {
    'filter_menu',
    'Filter menu',
    function()
      M.filter_menu()
    end,
  },
  {
    'clear_filters',
    'Clear filters',
    function()
      M.clear_filters()
    end,
  },
  {
    'group_by',
    'Choose grouping',
    function()
      M.choose_group_by()
    end,
  },
  {
    'status',
    'Choose PR status (refetch)',
    function()
      M.choose_status()
    end,
  },
  {
    'toggle_mine',
    'Toggle "created by me"',
    function()
      toggle_filter 'created_by_me'
    end,
  },
  {
    'toggle_needs_vote',
    'Toggle "needs my vote" (review queue)',
    function()
      toggle_filter 'needs_my_vote'
    end,
  },
  {
    'browser',
    'Open PR in browser',
    function()
      with_action 'open_in_browser'
    end,
  },
  {
    'yank_url',
    'Yank PR URL',
    function()
      with_action 'yank_url'
    end,
  },
  {
    'comment',
    'New comment on PR',
    function()
      local pr = M.pr_at_cursor()
      with_action('comment', function(err)
        if not err and pr then
          refresh_detail_of(pr)
        end
      end)
    end,
  },
  {
    'vote',
    'Vote on PR',
    function()
      local pr = M.pr_at_cursor()
      with_action('vote', function(err)
        if not err then
          M.refresh()
          if pr then
            refresh_detail_of(pr)
          end
        end
      end)
    end,
  },
  {
    'checkout',
    'Checkout source branch',
    function()
      -- actions.checkout asks for confirmation before running git
      with_action 'checkout'
    end,
  },
  {
    'help',
    'Show this help',
    function()
      M.show_help()
    end,
  },
  {
    'close',
    'Close',
    function()
      M.close()
    end,
  },
}

local function lhs_list(v)
  if v == false or v == nil then
    return {}
  end
  return type(v) == 'table' and v or { v }
end

local function set_keymaps(buf)
  local maps = (config.get().keymaps or {}).list or {}
  for _, a in ipairs(M.KEYMAP_ACTIONS) do
    for _, lhs in ipairs(lhs_list(maps[a[1]])) do
      vim.keymap.set('n', lhs, a[3], { buffer = buf, nowait = true, silent = true, desc = 'Azure PR: ' .. a[2] })
    end
  end
end

--- Floating window listing the list keymaps.
---@return integer|nil win
function M.show_help()
  local maps = (config.get().keymaps or {}).list or {}
  local rows, w_key = {}, 0
  for _, a in ipairs(M.KEYMAP_ACTIONS) do
    local keys = table.concat(lhs_list(maps[a[1]]), ' ')
    if keys ~= '' then
      rows[#rows + 1] = { keys, a[2] }
      w_key = math.max(w_key, vim.fn.strdisplaywidth(keys))
    end
  end
  local lines, hls = {}, {}
  for i, r in ipairs(rows) do
    lines[i] = ' ' .. util.pad_right(r[1], w_key) .. '  ' .. r[2] .. ' '
    hls[#hls + 1] = { i - 1, 1, 1 + #r[1], 'AzurePRKey' }
  end
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, highlights.ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'azure_pr_help'
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = math.min(width, math.max(vim.o.columns - 4, 10)),
    height = math.min(#lines, math.max(vim.o.lines - 4, 1)),
    row = math.max(math.floor((vim.o.lines - #lines) / 2) - 1, 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = 'minimal',
    border = 'rounded',
    title = ' Azure PR list keys ',
    title_pos = 'center',
  })
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, lhs in ipairs { 'q', '<Esc>', '?' } do
    vim.keymap.set('n', lhs, close, { buffer = buf, nowait = true, silent = true })
  end
  vim.api.nvim_create_autocmd('WinLeave', { buffer = buf, once = true, callback = close })
  return win
end

--------------------------------------------------------------------------------
-- Buffer / window
--------------------------------------------------------------------------------

local augroup = vim.api.nvim_create_augroup('AzurePRList', { clear = true })

local function create_buf()
  local existing = vim.fn.bufnr(M.BUF_NAME)
  if existing > 0 and vim.api.nvim_buf_is_valid(existing) then
    if vim.api.nvim_buf_is_loaded(existing) and vim.bo[existing].filetype == 'azure_pr_list' then
      view.buf = existing
      return existing
    end
    -- stale (e.g. after :bdelete, which resets buffer options and keymaps): wipe and recreate
    pcall(vim.api.nvim_buf_delete, existing, { force = true })
  end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, M.BUF_NAME)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'azure_pr_list'
  set_keymaps(buf)
  view.buf = buf
  view.items = {}
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = augroup,
    buffer = buf,
    callback = function()
      if view.buf == buf then
        view.buf = nil
        view.items = {}
      end
    end,
  })
  -- `:e`/`:e!` reloads this nofile buffer (emptying it): re-render from state
  vim.api.nvim_create_autocmd('BufReadCmd', {
    group = augroup,
    buffer = buf,
    callback = function()
      vim.bo[buf].modifiable = false
      M.render()
    end,
  })
  -- shown in another window (`:buffer`, bufferline cycling): apply the list window options there
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = augroup,
    buffer = buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(win) == buf then
        M._set_win_opts(win)
        M.render()
      end
    end,
  })
  return buf
end

local function set_win_opts(win)
  local function set(name, value)
    vim.api.nvim_set_option_value(name, value, { win = win, scope = 'local' })
  end
  set('wrap', false)
  set('cursorline', true)
  set('number', false)
  set('relativenumber', false)
  set('signcolumn', 'no')
  set('list', false)
  set('spell', false)
  set('foldenable', false)
end
M._set_win_opts = set_win_opts

--- Show `buf` according to config.list.layout; returns the window.
local function show(buf)
  local wins = vim.fn.win_findbuf(buf)
  -- prefer a window in the current tab, else any tab
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_get_tabpage(w) == vim.api.nvim_get_current_tabpage() then
      vim.api.nvim_set_current_win(w)
      return w
    end
  end
  if wins[1] then
    vim.api.nvim_set_current_win(wins[1])
    return wins[1]
  end
  local layout = (config.get().list or {}).layout or 'tab'
  if layout == 'tab' then
    vim.cmd 'tabnew'
    local scratch = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_buf(0, buf)
    -- drop the empty buffer created by :tabnew
    if scratch ~= buf and vim.api.nvim_buf_get_name(scratch) == '' and not vim.bo[scratch].modified then
      pcall(vim.api.nvim_buf_delete, scratch, {})
    end
  elseif layout == 'split' then
    vim.cmd 'split'
    vim.api.nvim_win_set_buf(0, buf)
  elseif layout == 'vsplit' then
    vim.cmd 'vsplit'
    vim.api.nvim_win_set_buf(0, buf)
  else
    vim.api.nvim_win_set_buf(0, buf)
  end
  return vim.api.nvim_get_current_win()
end

vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
  group = augroup,
  callback = function()
    if valid_buf() and #list_wins() > 0 and view.loaded then
      M.render()
    end
  end,
})

--- Open (or focus) the PR list and (re)fetch.
---@param opts { filters?: AzurePRFilters, group_by?: string, status?: string }|nil
---@return integer buf
function M.open(opts)
  opts = opts or {}
  local cfg = config.get()
  local first = state.group_by == nil -- state is fresh (first open or after reset)
  if opts.filters then
    state.filters = vim.deepcopy(opts.filters) --[[@as AzurePRFilters]]
  elseif first then
    state.filters = vim.deepcopy(cfg.default_filters or {})
  end
  state.filters = state.filters or {}
  local group_by = opts.group_by or state.group_by or cfg.default_group_by or 'repository'
  if group_by ~= state.group_by then
    state.collapsed = {}
  end
  state.group_by = group_by
  local status = opts.status or state.status or cfg.default_status or 'active'
  -- cached PRs are only shown while refetching when they belong to the requested status
  if first or status ~= state.status then
    view.loaded = false
  end
  state.status = status

  local buf = create_buf()
  local win = show(buf)
  set_win_opts(win)
  M.render()
  M.fetch()
  return buf
end

--- Buffer number of the list (nil if not created).
function M.bufnr()
  return valid_buf()
end

-- Test helpers
M._view = view

return M
