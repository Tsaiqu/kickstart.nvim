---@diagnostic disable: duplicate-set-field, need-check-nil, param-type-mismatch, assign-type-mismatch, redundant-parameter, cast-local-type, missing-parameter
-- Tests for azure_pr.actions with mocked api, ui.input, vim.ui.select and git.

local ME = { id = 'ME-ID', name = 'Me Myself', unique_name = 'me@example.com' }

local ctx -- per-test recorder

local function setup(opts)
  opts = opts or {}
  reset_modules()
  ctx = { calls = {}, notes = {}, inputs = {}, confirms = {}, selects = {}, git = {} }

  local api_mock = {
    _target = { organization = 'org', project = 'proj', base_url = 'https://dev.azure.com' },
  }
  local function recorder(name)
    return function(...)
      local args = { ... }
      local cb = table.remove(args)
      table.insert(ctx.calls, { name = name, args = args })
      local resp = opts.responses and opts.responses[name]
      if type(resp) == 'function' then
        return resp(cb, unpack(args))
      end
      cb(resp and resp.err or nil, resp and resp.result or { ok = true })
    end
  end
  for _, name in ipairs {
    'create_thread',
    'reply',
    'update_thread_status',
    'update_comment',
    'delete_comment',
    'vote',
    'list_pull_requests',
    'get_pull_request_by_id',
  } do
    api_mock[name] = recorder(name)
  end
  api_mock.get_current_user = function(cb)
    table.insert(ctx.calls, { name = 'get_current_user', args = {} })
    cb(nil, ME)
  end
  api_mock.web_url = function(pr)
    return 'https://dev.azure.com/org/proj/_git/' .. pr.repository.name .. '/pullrequest/' .. pr.id
  end
  package.loaded['azure_pr.api'] = api_mock

  package.loaded['azure_pr.ui.input'] = {
    open = function(o, on_submit)
      table.insert(ctx.inputs, o)
      -- submit only the first editor (a failed request reopens it pre-filled; that one stays open)
      if opts.input_text and #ctx.inputs == 1 then
        on_submit(opts.input_text)
      end
      return {}
    end,
    confirm = function(prompt, cb)
      table.insert(ctx.confirms, prompt)
      cb(opts.confirm ~= false)
    end,
  }

  local util = require 'azure_pr.util'
  util.notify = function(msg, level)
    table.insert(ctx.notes, { msg = msg, level = level })
  end

  ctx.orig_select = vim.ui.select
  vim.ui.select = function(items, o, on_choice)
    table.insert(ctx.selects, { items = items, opts = o })
    local labels = {}
    for i, item in ipairs(items) do
      labels[i] = o.format_item and o.format_item(item) or tostring(item)
    end
    ctx.selects[#ctx.selects].labels = labels
    local pick = opts.select
    if type(pick) == 'function' then
      pick = pick(items)
    end
    on_choice(pick)
  end

  local state = require 'azure_pr.state'
  state.reset()
  if opts.user ~= false then
    state.user = ME
  end

  local actions = require 'azure_pr.actions'
  actions._git = function(args, _, cb)
    local key = table.concat(args, ' ')
    table.insert(ctx.git, key)
    local r = (opts.git or {})[key] or { 1, '', 'unexpected git ' .. key }
    cb(r[1], r[2] or '', r[3] or '')
  end
  return actions, state
end

local function teardown()
  if ctx and ctx.orig_select then
    vim.ui.select = ctx.orig_select
  end
end

local function pr(over)
  return vim.tbl_extend('force', {
    id = 42,
    title = 'Add feature',
    status = 'active',
    is_draft = false,
    source_branch = 'feature/x',
    target_branch = 'main',
    repository = { id = 'REPO-ID', name = 'web' },
    author = { id = 'OTHER', name = 'Jan' },
    reviewers = {},
    review_state = 'no_votes',
  }, over or {})
end

local function thread(over)
  return vim.tbl_extend('force', {
    id = 7,
    status = 'active',
    comments = {
      { id = 1, parent_id = 0, author = { id = 'OTHER', name = 'Jan' }, content = 'first' },
      { id = 2, parent_id = 1, author = { id = 'me-id', name = 'Me Myself' }, content = 'mine\nsecond line' },
    },
  }, over or {})
end

local function last_call(name)
  for i = #ctx.calls, 1, -1 do
    if ctx.calls[i].name == name then
      return ctx.calls[i]
    end
  end
end

local function has_note(sub, level)
  for _, n in ipairs(ctx.notes) do
    if n.msg:find(sub, 1, true) and (level == nil or n.level == level) then
      return true
    end
  end
  return false
end

describe('actions.comment', function()
  it('creates a general thread from the input text and calls cb', function()
    local actions = setup { input_text = 'hello' }
    local got
    actions.comment(pr(), function(err, res)
      got = { err = err, res = res }
    end)
    teardown()
    local c = last_call 'create_thread'
    eq({ 'REPO-ID', 42, { content = 'hello', status = 'active' } }, c.args)
    eq({ err = nil, res = { ok = true } }, got)
    contains(ctx.inputs[1].title, '!42')
    truthy(has_note('Comment added', vim.log.levels.INFO))
  end)

  it('does nothing when input is cancelled', function()
    local actions = setup {}
    local called = false
    actions.comment(pr(), function()
      called = true
    end)
    teardown()
    falsy(last_call 'create_thread')
    falsy(called)
  end)

  it('reports API errors and passes them to cb', function()
    local actions = setup { input_text = 'x', responses = { create_thread = { err = 'HTTP 403' } } }
    local err
    actions.comment(pr(), function(e)
      err = e
    end)
    teardown()
    eq('HTTP 403', err)
    truthy(has_note('HTTP 403', vim.log.levels.ERROR))
  end)

  it('keeps the text after a failed request: register + reopened editor', function()
    local actions = setup { input_text = 'long review text', responses = { create_thread = { err = 'timeout' } } }
    vim.fn.setreg('"', '')
    actions.comment(pr())
    teardown()
    eq(2, #ctx.inputs)
    eq('long review text', ctx.inputs[2].initial)
    eq(ctx.inputs[1].title, ctx.inputs[2].title)
    eq('long review text', vim.fn.getreg '"')
    truthy(has_note('register', vim.log.levels.ERROR))
  end)

  it('a late failure after the user moved on stores a draft instead of popping up the editor', function()
    local later
    local actions, state = setup {
      input_text = 'late text',
      responses = {
        create_thread = function(cb)
          later = cb
        end,
      },
    }
    actions.comment(pr())
    vim.cmd 'split'
    later 'timeout'
    vim.cmd 'close'
    eq(1, #ctx.inputs, 'editor not reopened')
    eq('late text', state.drafts[ctx.inputs[1].title])
    truthy(has_note('draft', vim.log.levels.ERROR))
    actions.comment(pr())
    teardown()
    eq('late text', ctx.inputs[2].initial, 'repeating the action restores the draft')
    eq(nil, next(state.drafts))
  end)

  it('reply failure reopens the editor with the reply text', function()
    local actions = setup { input_text = 'my reply', responses = { reply = { err = 'HTTP 401' } } }
    actions.reply(pr(), thread(), nil)
    teardown()
    eq(2, #ctx.inputs)
    eq('my reply', ctx.inputs[2].initial)
  end)

  it('warns without a PR', function()
    local actions = setup { input_text = 'x' }
    actions.comment(nil)
    teardown()
    eq(0, #ctx.inputs)
    truthy(has_note('No pull request', vim.log.levels.WARN))
  end)
end)

describe('actions.reply', function()
  it('replies to the comment under cursor', function()
    local actions = setup { input_text = 'yes' }
    local t = thread()
    actions.reply(pr(), t, t.comments[2])
    teardown()
    eq({ 'REPO-ID', 42, 7, 'yes', 2 }, last_call('reply').args)
    contains(ctx.inputs[1].title, 'Me Myself')
  end)

  it('defaults parent to the first comment', function()
    local actions = setup { input_text = 'yes' }
    actions.reply(pr(), thread(), nil)
    teardown()
    eq(1, last_call('reply').args[5])
  end)

  it('warns without thread', function()
    local actions = setup { input_text = 'yes' }
    actions.reply(pr(), nil, nil)
    teardown()
    falsy(last_call 'reply')
    truthy(has_note('No comment thread', vim.log.levels.WARN))
  end)
end)

describe('actions.edit_comment / delete_comment', function()
  it('edits own comment with initial content', function()
    local actions = setup { input_text = 'edited' }
    local t = thread()
    actions.edit_comment(pr(), t, t.comments[2])
    wait_for(function()
      return last_call 'update_comment' ~= nil
    end)
    teardown()
    eq('mine\nsecond line', ctx.inputs[1].initial)
    eq({ 'REPO-ID', 42, 7, 2, 'edited' }, last_call('update_comment').args)
  end)

  it('refuses to edit someone else comment', function()
    local actions = setup { input_text = 'edited' }
    local t = thread()
    actions.edit_comment(pr(), t, t.comments[1])
    wait_for(function()
      return #ctx.notes > 0
    end)
    teardown()
    eq(0, #ctx.inputs)
    falsy(last_call 'update_comment')
    truthy(has_note('your own comments', vim.log.levels.WARN))
  end)

  it('fetches the current user when not cached', function()
    local actions, state = setup { input_text = 'edited', user = false }
    local t = thread()
    actions.edit_comment(pr(), t, t.comments[2])
    wait_for(function()
      return last_call 'update_comment' ~= nil
    end)
    teardown()
    truthy(last_call 'get_current_user')
    eq(ME, state.user)
  end)

  it('deletes own comment after confirmation', function()
    local actions = setup {}
    local t = thread()
    local done
    actions.delete_comment(pr(), t, t.comments[2], function(err)
      done = { err = err }
    end)
    wait_for(function()
      return done ~= nil
    end)
    teardown()
    eq({ 'REPO-ID', 42, 7, 2 }, last_call('delete_comment').args)
    contains(ctx.confirms[1], 'mine')
    eq({ err = nil }, done)
  end)

  it('does not delete when not confirmed', function()
    local actions = setup { confirm = false }
    local t = thread()
    actions.delete_comment(pr(), t, t.comments[2])
    wait_for(function()
      return #ctx.confirms > 0
    end)
    teardown()
    falsy(last_call 'delete_comment')
  end)
end)

describe('actions.set_thread_status', function()
  it('patches the chosen status and marks the current one', function()
    local actions = setup { select = 'fixed' }
    actions.set_thread_status(pr(), thread())
    teardown()
    eq({ 'REPO-ID', 42, 7, 'fixed' }, last_call('update_thread_status').args)
    contains(ctx.selects[1].labels, 'active  (current)')
    contains(ctx.selects[1].items, 'wontFix')
  end)

  it('skips when choosing the same status or cancelling', function()
    local actions = setup { select = 'active' }
    actions.set_thread_status(pr(), thread())
    teardown()
    falsy(last_call 'update_thread_status')
    actions = setup { select = nil }
    actions.set_thread_status(pr(), thread())
    teardown()
    falsy(last_call 'update_thread_status')
  end)
end)

describe('actions.vote', function()
  it('votes as current user and updates the PR locally', function()
    local actions = setup { select = 10 }
    local p = pr { reviewers = { { id = 'ME-ID', name = 'Me', vote = 0, is_required = true } } }
    local done
    actions.vote(p, function(err)
      done = { err = err }
    end)
    wait_for(function()
      return done ~= nil
    end)
    teardown()
    eq({ 'REPO-ID', 42, 'ME-ID', 10, { is_required = true } }, last_call('vote').args)
    eq(10, p.reviewers[1].vote)
    eq('approved', p.review_state)
    contains(ctx.selects[1].labels, 'Reset vote  (current)')
    eq({ 10, 5, -5, -10, 0 }, ctx.selects[1].items)
  end)

  it('also updates the copy of the PR held by the list state', function()
    local actions, state = setup { select = 10 }
    local list_copy = pr { reviewers = { { id = 'ME-ID', name = 'Me', vote = 0 } } }
    state.prs = { list_copy }
    local p = pr { reviewers = { { id = 'ME-ID', name = 'Me', vote = 0 } } }
    local done
    actions.vote(p, function(err)
      done = { err = err }
    end)
    wait_for(function()
      return done ~= nil
    end)
    teardown()
    eq(10, list_copy.reviewers[1].vote)
    eq('approved', list_copy.review_state)
  end)

  it('adds me as reviewer locally when not yet a reviewer', function()
    local actions = setup { select = -5 }
    local p = pr()
    actions.vote(p)
    wait_for(function()
      return last_call 'vote' ~= nil
    end)
    teardown()
    eq({}, last_call('vote').args[5])
    eq(1, #p.reviewers)
    eq(-5, p.reviewers[1].vote)
    eq('waiting', p.review_state)
  end)

  it('does not modify the PR on API error', function()
    local actions = setup { select = 10, responses = { vote = { err = 'boom' } } }
    local p = pr()
    local err
    actions.vote(p, function(e)
      err = e
    end)
    wait_for(function()
      return err ~= nil
    end)
    teardown()
    eq('boom', err)
    eq(0, #p.reviewers)
  end)

  it('refuses voting on completed PR', function()
    local actions = setup { select = 10 }
    actions.vote(pr { status = 'completed' })
    teardown()
    falsy(last_call 'vote')
    truthy(has_note('completed', vim.log.levels.WARN))
  end)
end)

describe('actions.yank_url / open_in_browser', function()
  it('yanks the web url into the unnamed register', function()
    local actions = setup {}
    local p = pr()
    local url = actions.yank_url(p)
    teardown()
    eq('https://dev.azure.com/org/proj/_git/web/pullrequest/42', url)
    eq(url, vim.fn.getreg '"')
    eq(url, p.url)
  end)

  it('opens the url via vim.ui.open', function()
    local actions = setup {}
    local orig = vim.ui.open
    local opened
    vim.ui.open = function(u)
      opened = u
      return {}
    end
    actions.open_in_browser(pr { url = 'https://x/pr/1' })
    vim.ui.open = orig
    teardown()
    eq('https://x/pr/1', opened)
    falsy(has_note('Failed', vim.log.levels.ERROR))
  end)

  it('reports a missing opener (vim.ui.open returns nil, err) with the url', function()
    local actions = setup {}
    local orig = vim.ui.open
    vim.ui.open = function()
      return nil, 'vim.ui.open: no handler found'
    end
    actions.open_in_browser(pr { url = 'https://x/pr/1' })
    vim.ui.open = orig
    teardown()
    truthy(has_note('no handler found', vim.log.levels.ERROR))
    truthy(has_note('https://x/pr/1', vim.log.levels.ERROR))
  end)
end)

describe('actions.checkout', function()
  it('fetches and checks out after confirmation', function()
    local actions = setup {
      git = { ['fetch origin +refs/heads/feature/x:refs/remotes/origin/feature/x'] = { 0 }, ['switch feature/x'] = { 0 } },
    }
    local done
    actions.checkout(pr(), function(err, branch)
      done = { err = err, branch = branch }
    end)
    teardown()
    eq({ 'fetch origin +refs/heads/feature/x:refs/remotes/origin/feature/x', 'switch feature/x' }, ctx.git)
    eq({ branch = 'feature/x' }, done)
    contains(ctx.confirms[1], 'feature/x')
  end)

  it('falls back to creating a tracking branch', function()
    local actions = setup {
      git = {
        ['fetch origin +refs/heads/feature/x:refs/remotes/origin/feature/x'] = { 0 },
        ['switch feature/x'] = { 128, '', 'fatal: invalid reference: feature/x' },
        ['switch -c feature/x --track origin/feature/x'] = { 0 },
      },
    }
    local done
    actions.checkout(pr(), function(err)
      done = { err = err }
    end)
    teardown()
    eq(3, #ctx.git)
    eq({ err = nil }, done)
  end)

  it('falls back to an untracked branch for narrow refspecs and reports the useful error', function()
    local actions = setup {
      git = {
        ['fetch origin +refs/heads/feature/x:refs/remotes/origin/feature/x'] = { 0 },
        ['switch feature/x'] = { 128, '', 'fatal: invalid reference: feature/x' },
        ['switch -c feature/x --track origin/feature/x'] = { 128, '', 'fatal: cannot set up tracking information' },
        ['switch -c feature/x origin/feature/x'] = { 0 },
      },
    }
    local done
    actions.checkout(pr(), function(err)
      done = { err = err }
    end)
    teardown()
    eq(4, #ctx.git)
    eq({ err = nil }, done)
    -- local changes block the switch: report that, not the "already exists" of the fallbacks
    actions = setup {
      git = {
        ['fetch origin +refs/heads/feature/x:refs/remotes/origin/feature/x'] = { 0 },
        ['switch feature/x'] = { 1, '', 'error: Your local changes would be overwritten' },
        ['switch -c feature/x --track origin/feature/x'] = { 128, '', "fatal: a branch named 'feature/x' already exists" },
        ['switch -c feature/x origin/feature/x'] = { 128, '', "fatal: a branch named 'feature/x' already exists" },
      },
    }
    local err
    actions.checkout(pr(), function(e)
      err = e
    end)
    teardown()
    contains(err, 'local changes')
    for _, cmd in ipairs(ctx.git) do
      falsy(cmd:match '^checkout', 'never uses git checkout (pathspec ambiguity)')
    end
  end)

  it('reports fetch failure', function()
    local actions = setup { git = { ['fetch origin +refs/heads/feature/x:refs/remotes/origin/feature/x'] = { 128, '', 'fatal: no remote' } } }
    local err
    actions.checkout(pr(), function(e)
      err = e
    end)
    teardown()
    eq('fatal: no remote', err)
    eq(1, #ctx.git)
  end)

  it('does nothing when not confirmed', function()
    local actions = setup { confirm = false }
    actions.checkout(pr())
    teardown()
    eq(0, #ctx.git)
  end)
end)

describe('actions.current_branch_pr', function()
  local remote = 'https://dev.azure.com/org/proj/_git/web'

  it('uses a cached PR from state', function()
    local actions, state = setup {
      git = { ['rev-parse --abbrev-ref HEAD'] = { 0, 'feature/x\n' }, ['remote get-url origin'] = { 0, remote .. '\n' } },
    }
    state.prs = { pr { id = 1, source_branch = 'other' }, pr { id = 2 }, pr { id = 3, repository = { id = 'R2', name = 'api' } } }
    local got
    actions.current_branch_pr(function(err, p)
      got = { err = err, id = p and p.id }
    end)
    teardown()
    eq({ id = 2 }, got)
    falsy(last_call 'list_pull_requests')
  end)

  it('fetches by source_ref and repository when not cached', function()
    local raw = {
      pullRequestId = 9,
      title = 'T',
      status = 'active',
      sourceRefName = 'refs/heads/feature/x',
      targetRefName = 'refs/heads/main',
      repository = { id = 'REPO-ID', name = 'web', project = { id = 'P', name = 'proj' } },
      createdBy = { id = 'OTHER', displayName = 'Jan' },
    }
    local actions = setup {
      git = { ['rev-parse --abbrev-ref HEAD'] = { 0, 'feature/x\n' }, ['remote get-url origin'] = { 0, remote } },
      responses = { list_pull_requests = { result = { raw } } },
    }
    local got
    actions.current_branch_pr(function(err, p)
      got = { err = err, p = p }
    end)
    teardown()
    eq({ { status = 'active', source_ref = 'feature/x', repository = 'web' } }, last_call('list_pull_requests').args)
    eq(9, got.p.id)
    eq('feature/x', got.p.source_branch)
    truthy(got.p.url)
  end)

  it('asks to choose when multiple PRs match', function()
    local actions, state = setup {
      git = { ['rev-parse --abbrev-ref HEAD'] = { 0, 'feature/x' }, ['remote get-url origin'] = { 1, '', 'no origin' } },
      select = function(items)
        return items[2]
      end,
    }
    state.prs = { pr { id = 1 }, pr { id = 2, repository = { id = 'R2', name = 'api' } } }
    local got
    actions.current_branch_pr(function(_, p)
      got = p
    end)
    teardown()
    eq(2, #ctx.selects[1].items)
    eq(2, got.id)
  end)

  it('errors for no PR, detached HEAD and non-repo', function()
    local actions = setup {
      git = { ['rev-parse --abbrev-ref HEAD'] = { 0, 'lonely' }, ['remote get-url origin'] = { 0, remote } },
      responses = { list_pull_requests = { result = {} } },
    }
    local err
    actions.current_branch_pr(function(e)
      err = e
    end)
    teardown()
    contains(err, 'No active pull request for branch lonely')

    actions = setup { git = { ['rev-parse --abbrev-ref HEAD'] = { 0, 'HEAD' } } }
    actions.current_branch_pr(function(e)
      err = e
    end)
    teardown()
    contains(err, 'detached')

    actions = setup { git = { ['rev-parse --abbrev-ref HEAD'] = { 128, '', 'fatal: not a git repository' } } }
    actions.current_branch_pr(function(e)
      err = e
    end)
    teardown()
    contains(err, 'not a git repository')
  end)
end)

describe('actions.comment_on_line', function()
  local dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir .. '/src/sub', 'p')
  local file = dir .. '/src/sub/file.lua'
  vim.fn.writefile({ 'a', 'b', 'c', 'd', 'e' }, file)

  local function git_ok()
    return {
      ['rev-parse --show-toplevel'] = { 0, dir .. '\n' },
      ['rev-parse --abbrev-ref HEAD'] = { 0, 'feature/x' },
      ['remote get-url origin'] = { 0, 'https://dev.azure.com/org/proj/_git/web' },
    }
  end

  it('creates a file thread for a range on the current branch PR', function()
    local actions, state = setup { input_text = 'look here', git = git_ok() }
    state.prs = { pr() }
    vim.cmd.edit(vim.fn.fnameescape(file))
    actions.comment_on_line { line1 = 4, line2 = 2 }
    teardown()
    eq(
      { 'REPO-ID', 42, { content = 'look here', status = 'active', file_path = 'src/sub/file.lua', line = 2, end_line = 4, end_offset = 2 } },
      last_call('create_thread').args
    )
    contains(ctx.inputs[1].title, 'src/sub/file.lua:2-4')
    vim.cmd 'bwipeout!'
  end)

  it('defaults to the cursor line and accepts an explicit pr', function()
    local actions = setup { input_text = 'x', git = git_ok() }
    vim.cmd.edit(vim.fn.fnameescape(file))
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local done
    actions.comment_on_line {
      pr = pr { id = 5 },
      cb = function(err)
        done = { err = err }
      end,
    }
    teardown()
    local args = last_call('create_thread').args
    eq(5, args[2])
    eq(3, args[3].line)
    eq(3, args[3].end_line)
    eq({ err = nil }, done)
    eq({ 'rev-parse --show-toplevel', 'rev-parse --abbrev-ref HEAD' }, ctx.git)
    eq(0, #ctx.confirms, 'HEAD is the source branch: no confirmation')
    vim.cmd 'bwipeout!'
  end)

  it('refuses non-file buffers', function()
    local actions = setup { input_text = 'x', git = git_ok() }
    vim.cmd 'enew'
    vim.bo.buftype = 'nofile'
    actions.comment_on_line {}
    teardown()
    eq(0, #ctx.git)
    truthy(has_note('file buffer', vim.log.levels.WARN))
    vim.cmd 'bwipeout!'
  end)

  it('notifies when no PR exists for the branch', function()
    local g = git_ok()
    local actions = setup { input_text = 'x', git = g, responses = { list_pull_requests = { result = {} } } }
    vim.cmd.edit(vim.fn.fnameescape(file))
    actions.comment_on_line { line1 = 1, line2 = 1 }
    teardown()
    falsy(last_call 'create_thread')
    truthy(has_note('No active pull request', vim.log.levels.WARN))
    vim.cmd 'bwipeout!'
  end)

  it('falls back to the last opened PR detail when the branch has no PR', function()
    local actions, state = setup { input_text = 'x', git = git_ok(), responses = { list_pull_requests = { result = {} } } }
    state.review_pr = pr { id = 77, source_branch = 'feature/other' }
    vim.cmd.edit(vim.fn.fnameescape(file))
    actions.comment_on_line { line1 = 1, line2 = 1 }
    teardown()
    eq(77, last_call('create_thread').args[2])
    truthy(has_note('!77', vim.log.levels.INFO))
    vim.cmd 'bwipeout!'
  end)

  it('offers a picker over loaded active PRs when nothing else fits', function()
    local actions, state = setup {
      input_text = 'x',
      git = git_ok(),
      responses = { list_pull_requests = { result = {} } },
      select = function(items)
        return items[2]
      end,
    }
    state.prs = { pr { id = 1, source_branch = 'a' }, pr { id = 2, source_branch = 'b' }, pr { id = 3, source_branch = 'c', status = 'completed' } }
    vim.cmd.edit(vim.fn.fnameescape(file))
    actions.comment_on_line { line1 = 1, line2 = 1 }
    teardown()
    eq(2, #ctx.selects[1].items)
    eq(2, last_call('create_thread').args[2])
    vim.cmd 'bwipeout!'
  end)

  it('uses the PR that opened the file buffer (b:azure_pr_id) before the branch PR', function()
    local actions, state = setup { input_text = 'x', git = git_ok() }
    state.prs = { pr { id = 42 }, pr { id = 9, source_branch = 'feature/y' } }
    vim.cmd.edit(vim.fn.fnameescape(file))
    vim.b.azure_pr_id = 9
    actions.comment_on_line { line1 = 1, line2 = 1 }
    teardown()
    eq(9, last_call('create_thread').args[2])
    eq({ 'rev-parse --show-toplevel', 'rev-parse --abbrev-ref HEAD' }, ctx.git, 'no PR lookup, only a HEAD check')
    eq(1, #ctx.confirms)
    contains(ctx.confirms[1], 'HEAD is feature/x, not feature/y')
    vim.cmd 'bwipeout!'
  end)

  it('does not comment when HEAD is not the PR source branch and the user declines', function()
    local actions, state = setup { input_text = 'x', git = git_ok(), confirm = false }
    state.prs = { pr { id = 9, source_branch = 'feature/y' } }
    vim.cmd.edit(vim.fn.fnameescape(file))
    vim.b.azure_pr_id = 9
    actions.comment_on_line { line1 = 1, line2 = 1 }
    teardown()
    eq(1, #ctx.confirms)
    eq(0, #ctx.inputs)
    falsy(last_call 'create_thread')
    vim.cmd 'bwipeout!'
  end)

  it('pr_id (":AzurePR comment <id>") fetches an unknown PR', function()
    local F = require 'azure_pr.tests.fixtures'
    local actions = setup {
      input_text = 'x',
      git = git_ok(),
      responses = { get_pull_request_by_id = { result = F.pr { pullRequestId = 555 } } },
    }
    vim.cmd.edit(vim.fn.fnameescape(file))
    actions.comment_on_line { line1 = 1, line2 = 1, pr_id = '555' }
    teardown()
    eq({ 555 }, last_call('get_pull_request_by_id').args)
    eq(555, last_call('create_thread').args[2])
    vim.cmd 'bwipeout!'
  end)
end)

describe('actions._git (real)', function()
  it('runs git asynchronously and calls back on the main loop', function()
    reset_modules()
    local actions = require 'azure_pr.actions'
    local res
    actions._git({ '--version' }, {}, function(code, out)
      res = { code = code, out = out, fast = vim.in_fast_event() }
    end)
    truthy(wait_for(function()
      return res ~= nil
    end, 5000))
    eq(0, res.code)
    contains(res.out, 'git version')
    eq(false, res.fast)
  end)
end)
