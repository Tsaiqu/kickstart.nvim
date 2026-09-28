---@diagnostic disable: duplicate-set-field, need-check-nil, param-type-mismatch, assign-type-mismatch, redundant-parameter, cast-local-type, missing-parameter
local F = require 'azure_pr.tests.fixtures'

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

local ME = { id = F.ME.id, name = F.ME.displayName, unique_name = F.ME.uniqueName }

local orig_select, orig_input, orig_notify = vim.ui.select, vim.ui.input, vim.notify

--- Fresh modules + mocked api/actions/detail. Returns ctx with call logs and helpers.
local function setup(cfg)
  vim.ui.select, vim.ui.input = orig_select, orig_input
  -- clean up windows/tabs/buffers of previous tests
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= '' then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  pcall(vim.cmd, 'silent! tabonly!')
  pcall(vim.cmd, 'silent! only!')
  vim.cmd 'enew!'
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match '^azure%-pr://' then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  reset_modules()

  local ctx = { list_calls = {}, actions = {}, detail = {}, notes = {}, prs = F.prs(), user_err = nil, list_err = nil, delay = 0 }
  vim.notify = function(msg, level)
    table.insert(ctx.notes, { msg = msg, level = level })
  end
  require('azure_pr.config').setup(vim.tbl_deep_extend('force', { organization = 'myorg', project = 'MyProject', icons = false }, cfg or {}))
  require('azure_pr.ui.highlights').setup()
  local api = require 'azure_pr.api'
  api.get_current_user = function(cb)
    vim.schedule(function()
      if ctx.user_err then
        cb(ctx.user_err)
      else
        cb(nil, ME)
      end
    end)
  end
  api.list_pull_requests = function(params, cb)
    table.insert(ctx.list_calls, params)
    local prs, err = vim.deepcopy(ctx.prs), ctx.list_err
    vim.defer_fn(function()
      if err then
        cb(err)
      else
        cb(nil, prs, { truncated = ctx.truncated == true })
      end
    end, ctx.delay)
  end
  local function recorder(name)
    return function(...)
      table.insert(ctx.actions, { name = name, args = { ... } })
    end
  end
  package.loaded['azure_pr.actions'] = {
    comment = recorder 'comment',
    vote = recorder 'vote',
    open_in_browser = recorder 'open_in_browser',
    yank_url = recorder 'yank_url',
    checkout = recorder 'checkout',
  }
  package.loaded['azure_pr.ui.detail'] = {
    open = function(pr)
      table.insert(ctx.detail, pr)
    end,
  }
  ctx.list = require 'azure_pr.ui.list'
  ctx.state = require 'azure_pr.state'
  ctx.lines = function()
    return vim.api.nvim_buf_get_lines(ctx.list.bufnr(), 0, -1, false)
  end
  ctx.text = function()
    return table.concat(ctx.lines(), '\n')
  end
  ctx.wait_loaded = function()
    return wait_for(function()
      return ctx.list._view.loaded and not ctx.list._view.loading
    end, 2000)
  end
  --- line number of the PR row with this id
  ctx.pr_line = function(id)
    for lnum, item in pairs(ctx.list._view.items) do
      if item.kind == 'pr' and item.pr.id == id then
        return lnum
      end
    end
  end
  ctx.group_line = function(key)
    for lnum, item in pairs(ctx.list._view.items) do
      if item.kind == 'group' and item.group_key == key then
        return lnum
      end
    end
  end
  ctx.shown_ids = function()
    local ids = {}
    for _, item in pairs(ctx.list._view.items) do
      if item.kind == 'pr' then
        table.insert(ids, item.pr.id)
      end
    end
    table.sort(ids)
    return ids
  end
  ctx.cursor_to = function(lnum)
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  end
  return ctx
end

--- Stub vim.ui.select to pick the first item for which pick(item, formatted) is true.
local function stub_select(...)
  local picks = { ... }
  local i = 0
  vim.ui.select = function(items, opts, cb)
    i = i + 1
    local pick = picks[i]
    for _, item in ipairs(items) do
      local label = opts.format_item and opts.format_item(item) or item
      if pick and pick(item, label) then
        return cb(item)
      end
    end
    cb(nil)
  end
end

local function label_has(s)
  return function(_, label)
    return label:find(s, 1, true) ~= nil
  end
end

describe('ui.list', function()
  it('opens the list buffer, shows loading, then renders grouped PRs', function()
    local ctx = setup()
    ctx.delay = 50
    local buf = ctx.list.open()
    eq(buf, vim.api.nvim_get_current_buf())
    eq('azure-pr://prs', vim.api.nvim_buf_get_name(buf))
    eq('nofile', vim.bo[buf].buftype)
    eq('hide', vim.bo[buf].bufhidden)
    eq('azure_pr_list', vim.bo[buf].filetype)
    falsy(vim.bo[buf].swapfile)
    falsy(vim.bo[buf].modifiable)
    falsy(vim.wo.wrap)
    truthy(vim.wo.cursorline)
    contains(ctx.text(), 'Loading')
    eq(2, #vim.api.nvim_list_tabpages(), 'layout tab opens a new tab')
    truthy(ctx.wait_loaded())
    eq({ { status = 'active' } }, ctx.list_calls)
    local text = ctx.text()
    contains(text, 'Azure DevOps PRs')
    contains(text, 'group: repository')
    contains(text, 'api-service')
    contains(text, 'Web App')
    contains(text, '!101')
    eq({ 101, 102, 103, 104, 105, 106, 107, 108, 109 }, ctx.shown_ids())
    eq(ME, ctx.state.user)
    eq(9, #ctx.state.prs)
    eq('https://dev.azure.com/myorg/MyProject/_git/api-service/pullrequest/101', ctx.list._view.items[ctx.pr_line(101)].pr.url)
    local marks = vim.api.nvim_buf_get_extmarks(buf, require('azure_pr.ui.highlights').ns, 0, -1, { details = true })
    truthy(#marks > 5, 'highlights applied')
    local item = ctx.list.item_at()
    truthy(item and (item.kind == 'group' or item.kind == 'pr'), 'cursor placed on first group/PR line')
  end)

  it('focuses the existing list instead of opening another one', function()
    local ctx = setup()
    local buf = ctx.list.open()
    ctx.wait_loaded()
    vim.cmd 'tabnext'
    eq(buf, ctx.list.open())
    eq(2, #vim.api.nvim_list_tabpages())
    eq(buf, vim.api.nvim_get_current_buf())
  end)

  it('honours layout current and applies opts.filters / group_by / status', function()
    local ctx = setup { list = { layout = 'current' } }
    local win = vim.api.nvim_get_current_win()
    ctx.list.open { filters = { created_by_me = true }, group_by = 'none', status = 'all' }
    ctx.wait_loaded()
    eq(win, vim.api.nvim_get_current_win())
    eq(1, #vim.api.nvim_list_tabpages())
    -- "created by me" is narrowed server-side too (creatorId), so max_prs cannot hide my PRs
    eq({ { status = 'all', creator_id = ME.id } }, ctx.list_calls)
    eq({ 102, 104 }, ctx.shown_ids())
    contains(ctx.text(), 'filter: mine')
    truthy(ctx.group_line '' ~= nil, "group 'none' renders a single group")
  end)

  it('applies config.default_filters and default_group_by on first open', function()
    local ctx = setup { default_filters = { repository = 'web' }, default_group_by = 'author' }
    ctx.list.open()
    ctx.wait_loaded()
    eq('author', ctx.state.group_by)
    eq({ 102, 103, 106 }, ctx.shown_ids())
  end)

  it('defines all configured buffer keymaps and respects overrides / false', function()
    local ctx = setup { keymaps = { list = { refresh = 'gr', checkout = false } } }
    local buf = ctx.list.open()
    ctx.wait_loaded()
    local function mapped(lhs)
      return vim.fn.maparg(lhs, 'n', false, true).buffer == 1
    end
    falsy(mapped '<Tab>', '<Tab> is not mapped by default (bufferline uses it globally)')
    for _, lhs in ipairs { '<CR>', 'za', '/', 'f', 'F', 'X', 'gb', 's', 'm', 'r', 'o', 'y', 'c', 'v', '?', 'q', 'gr' } do
      truthy(mapped(lhs), 'mapped ' .. lhs)
    end
    falsy(mapped 'R', 'R replaced by gr')
    falsy(mapped 'C', 'checkout disabled')
    eq(buf, vim.api.nvim_get_current_buf())
  end)

  it('za/<CR> on a group line folds and unfolds it', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    local n = #ctx.lines()
    ctx.cursor_to(ctx.group_line 'api-service')
    feed 'za'
    truthy(ctx.state.collapsed['api-service'])
    eq({ 102, 103, 106 }, ctx.shown_ids())
    eq(n - 6, #ctx.lines())
    eq(ctx.group_line 'api-service', vim.api.nvim_win_get_cursor(0)[1])
    feed '<CR>'
    falsy(ctx.state.collapsed['api-service'])
    eq(n, #ctx.lines())
  end)

  it('za on a PR line folds its group and moves the cursor to the group', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    ctx.cursor_to(ctx.pr_line(103))
    feed 'za'
    truthy(ctx.state.collapsed['Web App'])
    eq(ctx.group_line 'Web App', vim.api.nvim_win_get_cursor(0)[1])
  end)

  it('<CR> on a PR opens the detail view with the normalized PR', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    ctx.cursor_to(ctx.pr_line(105))
    feed '<CR>'
    eq(1, #ctx.detail)
    eq(105, ctx.detail[1].id)
    eq('Refactor models', ctx.detail[1].title)
  end)

  it('text filter via / uses vim.ui.input; empty input clears; cancel keeps', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    local answer = 'LOGIN'
    local prompts = {}
    vim.ui.input = function(opts, cb)
      table.insert(prompts, opts)
      cb(answer)
    end
    feed '/'
    eq('LOGIN', ctx.state.filters.text)
    eq({ 103 }, ctx.shown_ids())
    contains(ctx.text(), 'filter: text:"LOGIN"')
    answer = nil
    feed 'f'
    eq('LOGIN', ctx.state.filters.text, 'cancel keeps the filter')
    eq('LOGIN', prompts[2].default)
    answer = '  '
    feed 'f'
    eq(nil, ctx.state.filters.text)
    eq(9, #ctx.shown_ids())
  end)

  it('m / r toggle created_by_me and needs_my_vote; X clears', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    feed 'm'
    eq(true, ctx.state.filters.created_by_me)
    eq({ 102, 104 }, ctx.shown_ids())
    feed 'm'
    eq(nil, ctx.state.filters.created_by_me)
    feed 'r'
    eq({ 101, 109 }, ctx.shown_ids())
    feed 'X'
    eq({}, ctx.state.filters)
    eq(9, #ctx.shown_ids())
  end)

  it('shows a "no match" message when filters exclude everything', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    vim.ui.input = function(_, cb)
      cb 'zzz-nothing'
    end
    feed '/'
    eq({}, ctx.shown_ids())
    contains(ctx.text(), 'No pull requests match the filters')
  end)

  it('filter menu: author from list values, draft = non-drafts only, review state, toggles, clear all', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    stub_select(label_has 'Author:', function(item)
      return item == 'Anna Nowak'
    end)
    feed 'F'
    eq('=Anna Nowak', ctx.state.filters.author, 'picked values match exactly')
    eq({ 103, 105, 109 }, ctx.shown_ids())

    stub_select(label_has 'Draft:', function(item)
      return item == 'non-drafts only'
    end)
    feed 'F'
    eq(false, ctx.state.filters.draft)
    contains(ctx.text(), 'draft:no')

    stub_select(label_has 'Review state:', function(item)
      return item == 'rejected'
    end)
    feed 'F'
    eq({ 103 }, ctx.shown_ids())

    stub_select(label_has "I'm a reviewer")
    feed 'F'
    eq(true, ctx.state.filters.reviewer_is_me)

    stub_select(label_has 'Clear all')
    feed 'F'
    eq({}, ctx.state.filters)
  end)

  it('filter menu: custom typed value and (any)', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    vim.ui.input = function(_, cb)
      cb 'release'
    end
    stub_select(label_has 'Target branch:', label_has 'Type a value')
    feed 'F'
    eq('release', ctx.state.filters.target_branch)
    eq({ 109 }, ctx.shown_ids())
    stub_select(label_has 'Target branch:', label_has '(any)')
    feed 'F'
    eq(nil, ctx.state.filters.target_branch)
  end)

  it('g changes grouping (review_state order) and resets folds', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    ctx.state.collapsed['api-service'] = true
    stub_select(function(item)
      return item == 'review_state'
    end)
    feed 'gb'
    eq('review_state', ctx.state.group_by)
    eq({}, ctx.state.collapsed)
    contains(ctx.text(), 'group: review_state')
    local order = {}
    for lnum = 1, #ctx.lines() do
      local item = ctx.list._view.items[lnum]
      if item and item.kind == 'group' then
        table.insert(order, item.group_key)
      end
    end
    eq({ 'rejected', 'waiting', 'no_votes', 'approved_suggestions', 'approved', 'draft', 'completed', 'abandoned' }, order)
  end)

  it('s changes status and refetches, showing loading instead of stale PRs', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    ctx.delay = 50
    stub_select(function(item)
      return item == 'completed'
    end)
    feed 's'
    eq('completed', ctx.state.status)
    contains(ctx.text(), 'Loading')
    contains(ctx.text(), '[completed]')
    truthy(ctx.wait_loaded())
    eq({ status = 'completed' }, ctx.list_calls[2])
  end)

  it('R refresh keeps the cursor on the same PR when rows move', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    ctx.cursor_to(ctx.pr_line(106))
    local before = vim.api.nvim_win_get_cursor(0)[1]
    -- a newer PR in Web App pushes 106 down
    table.insert(ctx.prs, F.pr { pullRequestId = 110, repository = vim.deepcopy(F.REPO_WEB), creationDate = '2024-03-20T00:00:00Z' })
    feed 'R'
    truthy(ctx.wait_loaded())
    eq(2, #ctx.list_calls)
    local after = vim.api.nvim_win_get_cursor(0)[1]
    eq(ctx.pr_line(106), after)
    eq(before + 1, after)
    eq(106, ctx.list.pr_at_cursor().id)
  end)

  it('refresh keeps showing the old list while loading and ignores stale responses', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    ctx.delay = 80
    ctx.prs = { F.pr { pullRequestId = 201, title = 'stale' } }
    ctx.list.refresh()
    contains(ctx.text(), '!101', 'old data still visible')
    ctx.delay = 10
    ctx.prs = { F.pr { pullRequestId = 202, title = 'fresh' } }
    ctx.list.refresh()
    truthy(ctx.wait_loaded())
    vim.wait(150)
    eq({ 202 }, ctx.shown_ids())
  end)

  it('shows the error in the buffer and notifies when fetching fails', function()
    local ctx = setup()
    ctx.list_err = 'HTTP 401: bad PAT'
    ctx.list.open()
    truthy(wait_for(function()
      return not ctx.list._view.loading
    end))
    contains(ctx.text(), 'Error: HTTP 401: bad PAT')
    local found = false
    for _, n in ipairs(ctx.notes) do
      if n.level == vim.log.levels.ERROR and n.msg:find('bad PAT', 1, true) then
        found = true
      end
    end
    truthy(found, 'error notification')
    -- retry succeeds; while it is in flight the buffer says so (old error muted)
    ctx.list_err = nil
    ctx.delay = 50
    feed 'R'
    contains(ctx.text(), 'Retrying')
    contains(ctx.text(), 'Last error: HTTP 401')
    truthy(ctx.wait_loaded())
    contains(ctx.text(), '!101')
  end)

  it(':e in the list re-renders it from state', function()
    local ctx = setup()
    local buf = ctx.list.open()
    truthy(ctx.wait_loaded())
    vim.cmd 'edit'
    eq(buf, vim.api.nvim_get_current_buf())
    contains(ctx.text(), '!101')
    truthy(ctx.pr_line(101))
    falsy(vim.bo[buf].modifiable)
  end)

  it(':buffer in another window applies the list window options', function()
    local ctx = setup { list = { layout = 'vsplit' } }
    local other = vim.api.nvim_get_current_win()
    vim.wo[other].number = true
    vim.wo[other].signcolumn = 'yes'
    vim.wo[other].wrap = true
    local buf = ctx.list.open()
    truthy(ctx.wait_loaded())
    vim.api.nvim_set_current_win(other)
    vim.cmd('buffer ' .. buf)
    falsy(vim.wo[other].number)
    falsy(vim.wo[other].wrap)
    eq('no', vim.wo[other].signcolumn)
  end)

  it('keeps working when the current user cannot be fetched', function()
    local ctx = setup()
    ctx.user_err = 'boom'
    ctx.list.open()
    truthy(ctx.wait_loaded())
    eq(9, #ctx.shown_ids())
    feed 'm'
    eq({}, ctx.shown_ids(), 'me filters match nothing without a user')
  end)

  it('delegates o / y / c / v / C to azure_pr.actions with the PR under cursor', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    ctx.cursor_to(ctx.pr_line(104))
    for _, k in ipairs { 'o', 'y', 'c', 'v', 'C' } do
      feed(k)
    end
    local names = vim.tbl_map(function(a)
      return a.name
    end, ctx.actions)
    eq({ 'open_in_browser', 'yank_url', 'comment', 'vote', 'checkout' }, names)
    for _, a in ipairs(ctx.actions) do
      eq(104, a.args[1].id)
    end
    -- vote callback triggers a refresh on success only
    local calls = #ctx.list_calls
    ctx.actions[4].args[2] 'failed'
    eq(calls, #ctx.list_calls)
    ctx.actions[4].args[2](nil)
    eq(calls + 1, #ctx.list_calls)
    ctx.wait_loaded()
    -- on a group line nothing is called
    ctx.actions = {}
    ctx.cursor_to(ctx.group_line 'api-service')
    feed 'o'
    eq({}, ctx.actions)
    contains(ctx.notes[#ctx.notes].msg, 'No pull request under cursor')
  end)

  it('? opens a help float listing keys; q closes it', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    local list_win = vim.api.nvim_get_current_win()
    feed '?'
    local win = vim.api.nvim_get_current_win()
    truthy(vim.api.nvim_win_get_config(win).relative ~= '', 'help is a float')
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    contains(text, 'Toggle group fold')
    contains(text, 'za    Toggle group fold')
    contains(text, 'Checkout source branch')
    feed 'q'
    eq(list_win, vim.api.nvim_get_current_win())
  end)

  it('q closes the list tab', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    eq(2, #vim.api.nvim_list_tabpages())
    feed 'q'
    eq(1, #vim.api.nvim_list_tabpages())
    truthy(ctx.list.bufnr(), 'buffer is hidden, not wiped')
  end)

  it('q in the only window switches away from the list', function()
    local ctx = setup { list = { layout = 'current' } }
    local buf = ctx.list.open()
    ctx.wait_loaded()
    feed 'q'
    truthy(vim.api.nvim_get_current_buf() ~= buf)
  end)

  it('builds lines without a buffer (width aware) and never emits newlines', function()
    local ctx = setup()
    ctx.state.prs = require('azure_pr.models').normalize_prs(F.prs())
    ctx.state.group_by = 'none'
    ctx.list._view.loaded = true
    local res = ctx.list.build(80)
    for _, l in ipairs(res.lines) do
      falsy(l:find '\n', 'newline in line')
    end
    truthy(#res.lines > 9)
  end)
end)

vim.ui.select, vim.ui.input, vim.notify = orig_select, orig_input, orig_notify

describe('ui.list (review fixes)', function()
  it(':bdelete then reopen re-initialises the buffer', function()
    local ctx = setup()
    local buf = ctx.list.open()
    ctx.wait_loaded()
    vim.cmd('bdelete! ' .. buf)
    eq(nil, ctx.list.bufnr(), 'unloaded buffer is not used')
    local buf2 = ctx.list.open()
    ctx.wait_loaded()
    eq('nofile', vim.bo[buf2].buftype)
    eq('azure_pr_list', vim.bo[buf2].filetype)
    truthy(vim.fn.maparg('R', 'n', false, true).buffer == 1, 'keymaps present')
    truthy(ctx.pr_line(101))
  end)

  it('shows truncation and refetches with server-side scope when "mine" is toggled', function()
    local ctx = setup()
    ctx.truncated = true
    ctx.list.open()
    ctx.wait_loaded()
    contains(ctx.lines()[1], '+)')
    contains(ctx.lines()[1], 'max_prs reached')
    eq(1, #ctx.list_calls)
    feed 'm'
    wait_for(function()
      return #ctx.list_calls == 2
    end, 1000)
    ctx.wait_loaded()
    eq(ME.id, ctx.list_calls[2].creator_id)
    feed 'r'
    ctx.wait_loaded()
    eq(2, #ctx.list_calls, 'still creator scope: no refetch')
    feed 'm'
    wait_for(function()
      return #ctx.list_calls == 3
    end, 1000)
    ctx.wait_loaded()
    eq(ME.id, ctx.list_calls[3].reviewer_id)
  end)

  it('refetches for the new scope when a "me" filter changes during a fetch', function()
    local ctx = setup()
    ctx.delay = 100
    ctx.list.open { filters = { created_by_me = true } }
    truthy(wait_for(function()
      return #ctx.list_calls == 1
    end, 1000))
    eq(ME.id, ctx.list_calls[1].creator_id)
    feed 'm' -- turn "mine" off before the scoped fetch returns
    ctx.delay = 0
    truthy(wait_for(function()
      return #ctx.list_calls == 2 and ctx.list._view.loaded and not ctx.list._view.loading
    end, 2000))
    eq(nil, ctx.list_calls[2].creator_id)
    eq(nil, ctx.list._view.scope)
    eq({}, ctx.state.filters)
  end)

  it('marks the list as stale when a refresh fails after a successful load', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    ctx.list_err = 'HTTP 503: unavailable'
    local done = false
    ctx.list.refresh(function()
      done = true
    end)
    truthy(wait_for(function()
      return done
    end, 1000))
    contains(ctx.text(), '!101', 'old PRs still shown')
    local marks = vim.api.nvim_buf_get_extmarks(ctx.list.bufnr(), -1, { 0, 0 }, { 0, -1 }, { details = true })
    local virt = ''
    for _, m in ipairs(marks) do
      for _, chunk in ipairs(m[4].virt_text or {}) do
        virt = virt .. chunk[1]
      end
    end
    contains(virt, 'refresh failed: HTTP 503')
    contains(virt, 'retry')
    ctx.list_err = nil
    done = false
    ctx.list.refresh(function()
      done = true
    end)
    truthy(wait_for(function()
      return done
    end, 1000))
    eq(nil, ctx.list._view.error)
  end)

  it('complete (not truncated) list filters "mine" client-side without refetch', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    feed 'm'
    vim.wait(50)
    eq(1, #ctx.list_calls)
  end)

  it('picked filter values match exactly', function()
    local ctx = setup()
    ctx.list.open()
    ctx.wait_loaded()
    stub_select(label_has 'Target branch:', function(item)
      return item == 'main'
    end)
    feed 'F'
    eq('=main', ctx.state.filters.target_branch)
    contains(ctx.text(), 'target:=main')
    for _, id in ipairs(ctx.shown_ids()) do
      for _, pr in ipairs(ctx.state.prs) do
        if pr.id == id then
          eq('main', pr.target_branch)
        end
      end
    end
  end)
end)

vim.ui.select, vim.ui.input, vim.notify = orig_select, orig_input, orig_notify
