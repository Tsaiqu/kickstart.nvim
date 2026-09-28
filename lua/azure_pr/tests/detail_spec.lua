---@diagnostic disable: duplicate-set-field, need-check-nil, param-type-mismatch, assign-type-mismatch, redundant-parameter, cast-local-type, missing-parameter
-- Headless tests for ui/detail.lua with mocked api and actions.
local F = require 'azure_pr.tests.fixtures'

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

local function silence_notify()
  local orig = vim.notify
  local msgs = {}
  vim.notify = function(msg, level)
    table.insert(msgs, { msg = msg, level = level })
  end
  return msgs, function()
    vim.notify = orig
  end
end

--- Fake api: every call is recorded; responses come from `resp[name]` (value or function returning err, data).
local function fake_api(resp)
  local A = { calls = {}, resp = resp or {} }
  local function reply(name, cb, ...)
    table.insert(A.calls, { name = name, args = { ... } })
    local r = A.resp[name]
    local err, data
    if type(r) == 'function' then
      err, data = r(...)
    elseif type(r) == 'table' and r.err then
      err = r.err
    else
      data = vim.deepcopy(r)
    end
    vim.schedule(function()
      cb(err, data)
    end)
  end
  function A.get_pull_request(repo_id, pr_id, cb)
    reply('get_pull_request', cb, repo_id, pr_id)
  end
  function A.get_pull_request_by_id(pr_id, cb)
    reply('get_pull_request_by_id', cb, pr_id)
  end
  function A.list_threads(repo_id, pr_id, cb)
    reply('list_threads', cb, repo_id, pr_id)
  end
  function A.list_statuses(repo_id, pr_id, cb)
    reply('list_statuses', cb, repo_id, pr_id)
  end
  function A.list_policy_evaluations(project_id, pr_id, cb)
    reply('list_policy_evaluations', cb, project_id, pr_id)
  end
  function A.get_current_user(cb)
    reply('get_current_user', cb)
  end
  function A.web_url(pr)
    return 'https://dev.azure.com/myorg/MyProject/_git/' .. (pr.repository and pr.repository.name or 'x') .. '/pullrequest/' .. tostring(pr.id)
  end
  function A.count(name)
    local n = 0
    for _, c in ipairs(A.calls) do
      if c.name == name then
        n = n + 1
      end
    end
    return n
  end
  function A.find(name)
    for _, c in ipairs(A.calls) do
      if c.name == name then
        return c
      end
    end
  end
  return A
end

local function fake_actions()
  local calls = {}
  local act = { calls = calls }
  for _, name in ipairs { 'comment', 'reply', 'edit_comment', 'delete_comment', 'set_thread_status', 'vote', 'open_in_browser', 'yank_url' } do
    act[name] = function(...)
      table.insert(calls, { name = name, args = { ... } })
    end
  end
  function act.last(name)
    for i = #calls, 1, -1 do
      if calls[i].name == name then
        return calls[i]
      end
    end
  end
  return act
end

local function default_resp()
  return {
    get_pull_request = F.pr { reviewers = { F.reviewer(F.ME, 0, { isRequired = true }), F.reviewer(F.ANNA, 10) } },
    get_pull_request_by_id = F.pr(),
    list_threads = F.threads(),
    list_statuses = { { state = 'succeeded', context = { genre = 'ci', name = 'build' }, description = 'Build ok' } },
    list_policy_evaluations = { { status = 'approved', configuration = { isBlocking = true, type = { displayName = 'Minimum reviewers' } } } },
    get_current_user = { id = F.ME.id, name = F.ME.displayName, unique_name = F.ME.uniqueName },
  }
end

local function cleanup()
  vim.cmd 'silent! only'
  pcall(vim.cmd, 'silent! tabonly')
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= '' then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  vim.cmd 'enew!'
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match '^azure%-pr://' then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

--- Fresh modules with mocked api/actions. Returns detail, api mock, actions mock, notify msgs, restore.
local function setup(resp)
  cleanup()
  reset_modules()
  local A = fake_api(resp or default_resp())
  local act = fake_actions()
  package.loaded['azure_pr.api'] = A
  package.loaded['azure_pr.actions'] = act
  require('azure_pr.config').setup { icons = false }
  require('azure_pr.ui.highlights').setup()
  local msgs, restore = silence_notify()
  return require 'azure_pr.ui.detail', A, act, msgs, restore
end

local function normalized_pr()
  return require('azure_pr.models').normalize_pr(F.pr())
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function find_line(buf, pred)
  local st = require('azure_pr.ui.detail').get_state(buf)
  for l = 1, vim.api.nvim_buf_line_count(buf) do
    if pred(st.items[l], l) then
      return l
    end
  end
end

local function comment_line(buf, thread_id, comment_id)
  return find_line(buf, function(it)
    return it and it.kind == 'comment' and it.thread.id == thread_id and it.comment.id == comment_id
  end)
end

local function thread_line(buf, thread_id)
  return find_line(buf, function(it)
    return it and it.kind == 'thread' and it.thread.id == thread_id
  end)
end

local function loaded(detail, buf)
  return wait_for(function()
    local st = detail.get_state(buf)
    return st and not st.loading and st.threads and #st.threads > 0
  end, 2000)
end

describe('ui.detail', function()
  it('opens a buffer with name, options and loads everything in parallel', function()
    local detail, A, _, _, restore = setup()
    local buf = detail.open(normalized_pr())
    eq(buf, vim.api.nvim_get_current_buf())
    eq('azure-pr://pr/101', vim.api.nvim_buf_get_name(buf))
    eq('azure_pr_detail', vim.bo[buf].filetype)
    eq('nofile', vim.bo[buf].buftype)
    falsy(vim.bo[buf].modifiable)
    falsy(vim.bo[buf].swapfile)
    -- the known PR is shown immediately, before any response
    contains(lines(buf)[1], '!101')
    -- all requests started before the first one completes
    eq(1, A.count 'get_pull_request')
    eq(1, A.count 'list_threads')
    eq(1, A.count 'list_statuses')
    eq(1, A.count 'list_policy_evaluations')
    eq(1, A.count 'get_current_user')
    eq({ F.REPO_API.id, 101 }, A.find('get_pull_request').args)
    eq({ F.REPO_API.project.id, 101 }, A.find('list_policy_evaluations').args)
    truthy(loaded(detail, buf))
    local text = table.concat(lines(buf), '\n')
    contains(text, 'Please add a test')
    contains(text, 'for the timeout path')
    contains(text, 'Checks (2)')
    contains(text, 'ci/build')
    contains(text, 'Minimum reviewers')
    contains(text, 'Anna Nowak')
    contains(text, '(you)')
    eq(F.ME.id, detail.get_state(buf).user_id)
    eq('https://dev.azure.com/myorg/MyProject/_git/api-service/pullrequest/101', detail.get_state(buf).pr.url)
    -- system + deleted threads are dropped
    eq(3, #detail.get_state(buf).threads)
    restore()
  end)

  it('applies extmark highlights', function()
    local detail, _, _, _, restore = setup()
    local buf = detail.open(normalized_pr())
    truthy(loaded(detail, buf))
    local ns = require('azure_pr.ui.highlights').ns
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    truthy(#marks > 10, 'many highlight extmarks')
    local groups = {}
    for _, m in ipairs(marks) do
      groups[m[4].hl_group] = true
    end
    truthy(groups.AzurePRId)
    truthy(groups.AzurePRThreadActive)
    truthy(groups.AzurePRCommentAuthor)
    restore()
  end)

  it('tolerates failing statuses / policy evaluations', function()
    local resp = default_resp()
    resp.list_statuses = { err = 'HTTP 404' }
    resp.list_policy_evaluations = { err = 'HTTP 403: no permission' }
    local detail, _, _, msgs, restore = setup(resp)
    local buf = detail.open(normalized_pr())
    truthy(loaded(detail, buf))
    local text = table.concat(lines(buf), '\n')
    falsy(text:find('Checks', 1, true), 'no checks section')
    contains(text, 'Please add a test')
    eq(0, #msgs, 'no notifications for tolerated failures')
    eq('HTTP 404', detail.get_state(buf).check_errors.statuses)
    restore()
  end)

  it('opens from { id } only via the project-level lookup', function()
    local detail, A, _, _, restore = setup()
    local buf = detail.open { id = 101 }
    contains(lines(buf)[1], 'Loading PR !101')
    truthy(loaded(detail, buf))
    eq(1, A.count 'get_pull_request_by_id')
    eq(0, A.count 'get_pull_request', 'PR already known from the by-id lookup')
    eq({ F.REPO_API.id, 101 }, A.find('list_threads').args)
    eq(1, A.count 'list_policy_evaluations')
    contains(lines(buf)[1], 'Add retry policy')
    restore()
  end)

  it('shows an error when the PR cannot be loaded', function()
    local resp = default_resp()
    resp.get_pull_request = { err = 'HTTP 404: not found' }
    local detail, _, _, msgs, restore = setup(resp)
    local buf = detail.open { repository_id = 'r1', id = 555 }
    truthy(wait_for(function()
      return detail.get_state(buf).error ~= nil
    end))
    contains(lines(buf)[1], 'Failed to load PR !555')
    contains(table.concat(lines(buf), '\n'), 'HTTP 404: not found')
    eq(vim.log.levels.ERROR, msgs[#msgs].level)
    -- retry (R): the buffer shows that it is retrying, not the stale error screen
    feed 'R'
    contains(lines(buf)[1], 'Retrying PR !555')
    contains(table.concat(lines(buf), '\n'), 'Last error: HTTP 404')
    truthy(wait_for(function()
      return not detail.get_state(buf).loading
    end))
    contains(lines(buf)[1], 'Failed to load PR !555')
    restore()
  end)

  it(':e in the detail buffer keeps the view working', function()
    local detail, A, _, _, restore = setup()
    local buf = detail.open(normalized_pr(), { split = 'current' })
    truthy(loaded(detail, buf))
    local before = A.count 'get_pull_request'
    vim.cmd 'edit'
    vim.wait(20)
    eq(buf, vim.api.nvim_get_current_buf())
    truthy(vim.api.nvim_buf_is_valid(buf))
    truthy(detail.get_state(buf), 'state kept')
    eq(buf, select(2, detail.find_pr(detail.get_state(buf).pr.id)))
    truthy(wait_for(function()
      return A.count 'get_pull_request' > before and not detail.get_state(buf).loading
    end))
    truthy(vim.api.nvim_buf_line_count(buf) > 5, 're-rendered')
    feed 'R'
    truthy(
      wait_for(function()
        return A.count 'get_pull_request' > before + 1
      end),
      'R still works'
    )
    restore()
  end)

  it('reuses the buffer when the same PR is opened again', function()
    local detail, A, _, _, restore = setup()
    local buf = detail.open(normalized_pr())
    truthy(loaded(detail, buf))
    vim.cmd 'enew'
    local buf2 = detail.open(normalized_pr())
    eq(buf, buf2)
    eq(buf, vim.api.nvim_get_current_buf())
    truthy(wait_for(function()
      return A.count 'get_pull_request' == 2 and not detail.get_state(buf).loading
    end))
    restore()
  end)

  it('opens in a vertical split when invoked from the PR list', function()
    local detail, _, _, _, restore = setup()
    local list_win = vim.api.nvim_get_current_win()
    vim.bo.filetype = 'azure_pr_list'
    local buf = detail.open(normalized_pr())
    eq(2, #vim.api.nvim_tabpage_list_wins(0))
    truthy(vim.api.nvim_get_current_win() ~= list_win)
    eq(buf, vim.api.nvim_get_current_buf())
    -- opening another PR from the list reuses the detail window
    vim.api.nvim_set_current_win(list_win)
    local other = require('azure_pr.models').normalize_pr(F.pr { pullRequestId = 202, title = 'Other' })
    local buf2 = detail.open(other)
    eq(2, #vim.api.nvim_tabpage_list_wins(0))
    eq(buf2, vim.api.nvim_get_current_buf())
    truthy(loaded(detail, buf2))
    restore()
  end)

  it('defines all configured buffer-local keymaps', function()
    local detail, _, _, _, restore = setup()
    local buf = detail.open(normalized_pr())
    local maps = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      maps[m.lhs] = true
    end
    -- no <Tab> (global bufferline mapping), no v / y (visual mode and yank stay usable)
    falsy(maps['<Tab>'] or maps['v'] or maps['y'], 'Tab/v/y not shadowed')
    for _, lhs in ipairs { 'c', 'r', 'e', 'd', 's', 't', 'za', '<CR>', 'A', 'o', 'gy', 'R', 'q', '?', '[t', ']t' } do
      truthy(maps[lhs] or maps[vim.api.nvim_replace_termcodes(lhs, true, false, true)], 'keymap ' .. lhs)
    end
    restore()
  end)

  it('respects disabled / remapped keys', function()
    local detail, _, _, _, restore = setup()
    require('azure_pr.config').setup { icons = false, keymaps = { detail = { vote = false, refresh = 'gr' } } }
    local buf = detail.open(normalized_pr())
    local maps = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      maps[m.lhs] = true
    end
    falsy(maps.v)
    falsy(maps.R)
    truthy(maps.gr)
    restore()
  end)

  it('maps cursor lines to items and replies with the comment under cursor', function()
    local detail, A, act, _, restore = setup()
    local buf = detail.open(normalized_pr())
    truthy(loaded(detail, buf))
    local l = comment_line(buf, 11, 2)
    truthy(l)
    vim.api.nvim_win_set_cursor(0, { l, 0 })
    local item = detail.item_at(buf)
    eq('comment', item.kind)
    eq(2, item.comment.id)
    feed 'r'
    local call = act.last 'reply'
    truthy(call, 'actions.reply called')
    eq(101, call.args[1].id)
    eq(11, call.args[2].id)
    eq(2, call.args[3].id)
    -- on the thread header the parent is the first comment
    vim.api.nvim_win_set_cursor(0, { thread_line(buf, 11), 0 })
    feed 'r'
    eq(1, act.last('reply').args[3].id)
    -- the callback refreshes on success only
    local before = A.count 'get_pull_request'
    act.last('reply').args[4] 'boom'
    eq(before, A.count 'get_pull_request')
    act.last('reply').args[4](nil, {})
    eq(before + 1, A.count 'get_pull_request')
    truthy(wait_for(function()
      return not detail.get_state(buf).loading
    end))
    restore()
  end)

  it('reply / status need a thread under cursor', function()
    local detail, _, act, msgs, restore = setup()
    local buf = detail.open(normalized_pr())
    truthy(loaded(detail, buf))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    feed 'r'
    feed 's'
    eq(nil, act.last 'reply')
    eq(nil, act.last 'set_thread_status')
    eq(2, #msgs)
    vim.api.nvim_win_set_cursor(0, { comment_line(buf, 12, 1), 0 })
    feed 's'
    eq(12, act.last('set_thread_status').args[2].id)
    restore()
  end)

  it('edits / deletes only own comments', function()
    local detail, _, act, msgs, restore = setup()
    local buf = detail.open(normalized_pr())
    truthy(loaded(detail, buf))
    vim.api.nvim_win_set_cursor(0, { comment_line(buf, 11, 1), 0 }) -- Jan's comment
    feed 'e'
    feed 'd'
    eq(nil, act.last 'edit_comment')
    eq(nil, act.last 'delete_comment')
    contains(msgs[#msgs].msg, 'your own comments')
    vim.api.nvim_win_set_cursor(0, { comment_line(buf, 11, 2) + 1, 0 }) -- body line of my comment
    feed 'e'
    eq(2, act.last('edit_comment').args[3].id)
    feed 'd'
    eq(2, act.last('delete_comment').args[3].id)
    eq(11, act.last('delete_comment').args[2].id)
    restore()
  end)

  it('general comment, vote, browser, yank delegate to actions', function()
    local detail, _, act, _, restore = setup()
    local buf = detail.open(normalized_pr())
    truthy(loaded(detail, buf))
    feed 'c'
    feed 'A'
    feed 'o'
    feed 'gy'
    for _, name in ipairs { 'comment', 'vote', 'open_in_browser', 'yank_url' } do
      truthy(act.last(name), name)
      eq(101, act.last(name).args[1].id)
    end
    restore()
  end)

  it('folds threads and toggles resolved threads keeping the cursor', function()
    local detail, _, _, _, restore = setup()
    local buf = detail.open(normalized_pr())
    truthy(loaded(detail, buf))
    local n_before = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(0, { comment_line(buf, 11, 2), 0 })
    feed 'za'
    truthy(detail.get_state(buf).folded[11])
    eq(nil, comment_line(buf, 11, 2))
    eq(thread_line(buf, 11), vim.api.nvim_win_get_cursor(0)[1])
    truthy(vim.api.nvim_buf_line_count(buf) < n_before)
    feed 'za'
    falsy(detail.get_state(buf).folded[11])
    truthy(comment_line(buf, 11, 2))
    -- hide resolved: threads 12 (fixed) and 15 (wontFix) disappear, cursor stays on 11
    feed 't'
    falsy(detail.get_state(buf).show_resolved)
    eq(nil, thread_line(buf, 12))
    eq(nil, thread_line(buf, 15))
    eq(thread_line(buf, 11), vim.api.nvim_win_get_cursor(0)[1])
    contains(table.concat(lines(buf), '\n'), '2 resolved hidden')
    feed 't'
    truthy(thread_line(buf, 12))
    restore()
  end)

  it('jumps between threads with ]t / [t', function()
    local detail, _, _, _, restore = setup()
    local buf = detail.open(normalized_pr())
    truthy(loaded(detail, buf))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    feed ']t'
    eq(thread_line(buf, 12), vim.api.nvim_win_get_cursor(0)[1])
    feed ']t'
    eq(thread_line(buf, 11), vim.api.nvim_win_get_cursor(0)[1])
    feed ']t'
    eq(thread_line(buf, 15), vim.api.nvim_win_get_cursor(0)[1])
    feed ']t' -- no next: stays
    eq(thread_line(buf, 15), vim.api.nvim_win_get_cursor(0)[1])
    feed '[t'
    eq(thread_line(buf, 11), vim.api.nvim_win_get_cursor(0)[1])
    restore()
  end)

  it('refresh keeps the cursor on the same comment when lines shift', function()
    local resp = default_resp()
    local detail, A, _, _, restore = setup(resp)
    local buf = detail.open(normalized_pr())
    truthy(loaded(detail, buf))
    local l = comment_line(buf, 11, 1)
    vim.api.nvim_win_set_cursor(0, { l + 1, 0 }) -- second body line of Jan's comment
    -- a new, earlier thread and a longer description push everything down
    local threads = F.threads()
    table.insert(threads, {
      id = 20,
      publishedDate = '2024-03-09T00:00:00Z',
      status = 'active',
      comments = { F.comment(1, F.ANNA, 'first!\nsecond line\nthird line', { publishedDate = '2024-03-09T00:00:00Z' }) },
    })
    A.resp.list_threads = threads
    A.resp.get_pull_request = F.pr { description = 'one\ntwo\nthree\nfour\nfive' }
    feed 'R'
    truthy(wait_for(function()
      return A.count 'list_threads' == 2 and not detail.get_state(buf).loading
    end))
    truthy(thread_line(buf, 20))
    local nl = comment_line(buf, 11, 1)
    truthy(nl > l, 'lines shifted')
    eq(nl + 1, vim.api.nvim_win_get_cursor(0)[1])
    restore()
  end)

  it('ignores stale responses from an older load', function()
    local resp = default_resp()
    local detail, A, _, _, restore = setup(resp)
    local buf = detail.open(normalized_pr())
    -- second load starts before the first finishes; only its data must win
    A.resp.get_pull_request = F.pr { title = 'Newest title' }
    detail.refresh(buf)
    truthy(wait_for(function()
      return A.count 'get_pull_request' == 2 and not detail.get_state(buf).loading and #detail.get_state(buf).threads > 0
    end))
    vim.wait(50)
    contains(lines(buf)[1], 'Newest title')
    restore()
  end)

  it('warns about base-side threads and a different HEAD when opening files', function()
    local detail, _, act, msgs, restore = setup()
    act._git = function(_, _, cb)
      cb(0, 'main\n', '')
    end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/src/http', 'p')
    local file_lines = {}
    for i = 1, 60 do
      file_lines[i] = 'line ' .. i
    end
    vim.fn.writefile(file_lines, dir .. '/src/http/client.lua')
    vim.fn.writefile(file_lines, dir .. '/README.md')
    local buf = detail.open(normalized_pr())
    truthy(loaded(detail, buf))
    local dwin = vim.api.nvim_get_current_win()
    contains(table.concat(lines(buf), '\n'), 'README.md:3 (base)')
    local old_cwd = vim.fn.getcwd()
    -- left-side (base version) thread: file opened, no jump
    vim.api.nvim_win_set_cursor(0, { thread_line(buf, 15), 0 })
    vim.cmd.cd(dir)
    local ok, err = pcall(feed, '<CR>')
    vim.cmd.cd(old_cwd)
    assert(ok, err)
    contains(vim.api.nvim_buf_get_name(0), 'README.md')
    eq(1, vim.api.nvim_win_get_cursor(0)[1])
    contains(msgs[#msgs].msg, 'base version')
    -- right-side thread with another branch checked out: jump + warning
    vim.api.nvim_set_current_win(dwin)
    vim.api.nvim_win_set_cursor(0, { comment_line(buf, 11, 1), 0 })
    vim.cmd.cd(dir)
    ok, err = pcall(feed, '<CR>')
    vim.cmd.cd(old_cwd)
    assert(ok, err)
    eq(42, vim.api.nvim_win_get_cursor(0)[1])
    contains(msgs[#msgs].msg, 'HEAD is main, not feature/retry')
    vim.fn.delete(dir, 'rf')
    restore()
  end)

  it('opens the file of a file thread at its line', function()
    local detail, _, _, msgs, restore = setup()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/src/http', 'p')
    local file_lines = {}
    for i = 1, 60 do
      file_lines[i] = 'line ' .. i
    end
    vim.fn.writefile(file_lines, dir .. '/src/http/client.lua')
    local buf = detail.open(normalized_pr())
    truthy(loaded(detail, buf))
    local dwin = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(0, { comment_line(buf, 11, 1), 0 })
    -- the runner's package.path is relative to the config dir: only change cwd around the key press
    local old_cwd = vim.fn.getcwd()
    vim.cmd.cd(dir)
    local ok, err = pcall(feed, '<CR>')
    vim.cmd.cd(old_cwd)
    assert(ok, err)
    truthy(vim.api.nvim_get_current_win() ~= dwin, 'file opened in another window')
    contains(vim.api.nvim_buf_get_name(0), 'src/http/client.lua')
    eq(42, vim.api.nvim_win_get_cursor(0)[1])
    -- line comments from this buffer target the PR (actions.comment_on_line)
    eq(detail.get_state(buf).pr.id, vim.b.azure_pr_id)
    eq(detail.get_state(buf).pr, require('azure_pr.state').review_pr)
    eq(detail.get_state(buf).pr, (detail.find_pr(detail.get_state(buf).pr.id)))
    truthy(vim.api.nvim_win_is_valid(dwin), 'detail window kept')
    -- README.md does not exist -> warning, nothing opened
    vim.api.nvim_set_current_win(dwin)
    vim.api.nvim_win_set_cursor(0, { thread_line(buf, 15), 0 })
    vim.cmd.cd(dir)
    ok, err = pcall(feed, '<CR>')
    vim.cmd.cd(old_cwd)
    assert(ok, err)
    eq(dwin, vim.api.nvim_get_current_win())
    contains(msgs[#msgs].msg, 'README.md')
    -- <CR> on a general thread header folds it
    vim.api.nvim_win_set_cursor(0, { thread_line(buf, 12), 0 })
    feed '<CR>'
    truthy(detail.get_state(buf).folded[12])
    vim.fn.delete(dir, 'rf')
    restore()
  end)

  it('shows a help float and closes the view', function()
    local detail, _, _, _, restore = setup()
    local buf = detail.open(normalized_pr())
    truthy(loaded(detail, buf))
    feed '?'
    local win = vim.api.nvim_get_current_win()
    eq('editor', vim.api.nvim_win_get_config(win).relative)
    local help = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    contains(help, 'Reply to thread')
    contains(help, '[t')
    feed 'q'
    falsy(vim.api.nvim_win_is_valid(win))
    eq(buf, vim.api.nvim_get_current_buf())
    -- with a split: q closes only the detail window
    vim.cmd 'vsplit'
    eq(2, #vim.api.nvim_tabpage_list_wins(0))
    feed 'q'
    eq(1, #vim.api.nvim_tabpage_list_wins(0))
    -- last window: the buffer is dropped
    feed 'q'
    falsy(vim.api.nvim_buf_is_valid(buf))
    eq(nil, detail.get_state(buf))
    restore()
  end)
end)

cleanup()

describe('ui.detail (review fixes)', function()
  it(':bdelete of the detail buffer does not leave a broken view on reopen', function()
    local detail, _, _, _, restore = setup()
    vim.cmd 'vsplit'
    local buf = detail.open(normalized_pr(), { split = 'current' })
    truthy(loaded(detail, buf))
    vim.cmd('bdelete ' .. buf)
    eq(nil, detail.get_state(buf), 'state dropped on unload')
    local buf2 = detail.open(normalized_pr(), { split = 'current' })
    truthy(loaded(detail, buf2))
    eq('nofile', vim.bo[buf2].buftype)
    eq('azure_pr_detail', vim.bo[buf2].filetype)
    truthy(vim.fn.maparg('c', 'n', false, true).buffer == 1, 'keymaps present')
    wait_for(function()
      return not vim.api.nvim_buf_is_valid(buf) or buf == buf2
    end, 500)
    restore()
  end)

  it('shows loading and error states for threads instead of "No comments yet"', function()
    local resp = default_resp()
    resp.list_threads = { err = 'HTTP 500' }
    local detail, _, _, _, restore = setup(resp)
    local buf = detail.open(normalized_pr(), { split = 'current' })
    local text = table.concat(lines(buf), '\n')
    contains(text, 'Loading comments')
    wait_for(function()
      local st = detail.get_state(buf)
      return st and not st.loading
    end, 2000)
    text = table.concat(lines(buf), '\n')
    contains(text, 'Failed to load threads: HTTP 500')
    falsy(text:find('No comments yet', 1, true))
    restore()
  end)
end)

cleanup()
