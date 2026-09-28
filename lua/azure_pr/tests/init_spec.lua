---@diagnostic disable: duplicate-set-field, need-check-nil, param-type-mismatch, assign-type-mismatch, redundant-parameter, cast-local-type, missing-parameter
local azure = require 'azure_pr'

local function global_map(mode, lhs)
  local m = vim.fn.maparg(lhs, mode, false, true)
  return m and m.lhs and m or nil
end

-- Replace a lazily-required module with a stub for the duration of a test.
local function stub_module(name, tbl)
  package.loaded[name] = tbl
end

describe('init.setup', function()
  it('creates :AzurePR and is idempotent', function()
    vim.g.mapleader = ' '
    azure.setup {}
    eq(2, vim.fn.exists ':AzurePR')
    azure.setup {}
    azure.setup { organization = 'o', project = 'p' }
    eq(2, vim.fn.exists ':AzurePR')
    eq('o', require('azure_pr.config').get().organization)
    local cmds = vim.api.nvim_get_commands {}
    truthy(cmds.AzurePR)
    eq('*', cmds.AzurePR.nargs)
    truthy(cmds.AzurePR.range ~= nil and cmds.AzurePR.range ~= '', 'range enabled')
  end)

  it('does not call git or network during setup', function()
    local config = require 'azure_pr.config'
    local orig_git, orig_sys = config._git_remote, vim.system
    local called = false
    config._git_remote = function()
      called = true
    end
    vim.system = function(...)
      called = true
      return orig_sys(...)
    end
    local ok, err = pcall(azure.setup, {})
    config._git_remote, vim.system = orig_git, orig_sys
    truthy(ok, err)
    falsy(called, 'setup spawned a process')
  end)

  it('sets global keymaps with desc and replaces them on re-setup', function()
    azure.setup {}
    local m = global_map('n', '<leader>pl')
    truthy(m, '<leader>pl mapped')
    contains(m.desc, 'Azure')
    truthy(global_map('x', '<leader>pa'), 'visual comment map')
    azure.setup { keymaps = { global = { list = '<leader>pL' } } }
    falsy(global_map('n', '<leader>pl'), 'old lhs removed')
    truthy(global_map('n', '<leader>pL'))
    azure.setup { keymaps = { global = { enabled = false } } }
    falsy(global_map('n', '<leader>pL'))
    falsy(global_map('n', '<leader>pm'))
    azure.setup {}
    truthy(global_map('n', '<leader>pm'))
  end)

  it('defines highlight groups', function()
    azure.setup {}
    truthy(next(vim.api.nvim_get_hl(0, { name = 'AzurePRTitle' })), 'AzurePRTitle defined')
  end)
end)

describe('init.complete', function()
  it('lists subcommands', function()
    local c = azure.complete('', 'AzurePR ')
    for _, name in ipairs { 'list', 'mine', 'review', 'open', 'current', 'comment', 'refresh', 'clear_cache' } do
      contains(c, name)
    end
    eq(vim.fn.sort(vim.deepcopy(c)), c)
  end)
  it('filters by prefix and works with a range', function()
    eq({ 'clear_cache', 'comment', 'current' }, azure.complete('c', 'AzurePR c'))
    eq({ 'comment' }, azure.complete('com', "'<,'>AzurePR com"))
  end)
  it('completes list statuses', function()
    eq({ 'active', 'completed', 'abandoned', 'all' }, azure.complete('', 'AzurePR list '))
    eq({ 'active', 'abandoned', 'all' }, azure.complete('a', 'AzurePR list a'))
    eq({}, azure.complete('', 'AzurePR mine '))
    eq({}, azure.complete('', 'AzurePR list active '))
  end)
  it('is wired to the command-line completion', function()
    azure.setup {}
    local c = vim.fn.getcompletion('AzurePR re', 'cmdline')
    eq({ 'refresh', 'review' }, c)
  end)
end)

describe('init.command dispatch', function()
  it('routes subcommands to the ui modules', function()
    azure.setup {}
    local calls = {}
    stub_module('azure_pr.ui.list', {
      open = function(o)
        table.insert(calls, { 'list', o })
      end,
      refresh = function()
        table.insert(calls, { 'refresh' })
      end,
    })
    stub_module('azure_pr.actions', {
      comment_on_line = function(o)
        table.insert(calls, { 'comment', o.line1, o.line2, o.pr_id })
      end,
      current_branch_pr = function(cb)
        cb(nil, { id = 7 })
      end,
    })
    stub_module('azure_pr.ui.detail', {
      open = function(pr)
        table.insert(calls, { 'detail', pr.id })
      end,
    })
    vim.cmd 'AzurePR'
    vim.cmd 'AzurePR list completed'
    vim.cmd 'AzurePR mine'
    vim.cmd 'AzurePR review'
    vim.cmd 'AzurePR refresh'
    vim.cmd 'AzurePR current'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a', 'b', 'c', 'd' })
    vim.cmd '2,3AzurePR comment'
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.cmd 'AzurePR comment'
    vim.cmd 'AzurePR comment !55'
    eq({
      { 'list', {} },
      { 'list', { status = 'completed' } },
      { 'list', { filters = { created_by_me = true } } },
      { 'list', { filters = { needs_my_vote = true }, status = 'active' } },
      { 'refresh' },
      { 'detail', 7 },
      { 'comment', 2, 3 },
      { 'comment', 4, 4 },
      { 'comment', 4, 4, '55' },
    }, calls)
  end)

  it('opens a PR by id via the api', function()
    local opened
    stub_module('azure_pr.api', {
      get_pull_request_by_id = function(id, cb)
        cb(nil, { pullRequestId = id, title = 'T', status = 'active', repository = { id = 'r', name = 'repo' } })
      end,
      web_url = function()
        return 'https://example/pr'
      end,
    })
    stub_module('azure_pr.ui.detail', {
      open = function(pr)
        opened = pr
      end,
    })
    vim.cmd 'AzurePR open 42'
    truthy(opened)
    eq(42, opened.id)
    eq('T', opened.title)
    opened = nil
    vim.cmd 'AzurePR open !43'
    eq(43, opened and opened.id)
  end)

  it('warns on unknown subcommand and bad args without erroring', function()
    local msgs = {}
    local orig = vim.notify
    vim.notify = function(m)
      table.insert(msgs, m)
    end
    vim.cmd 'AzurePR bogus'
    vim.cmd 'AzurePR list nope'
    vim.cmd 'AzurePR open abc'
    vim.notify = orig
    eq(3, #msgs)
    contains(msgs[1], 'Unknown subcommand')
    contains(msgs[2], 'Unknown status')
    contains(msgs[3], 'Usage')
  end)

  it('clear_cache resets state and config caches', function()
    local state = require 'azure_pr.state'
    state.prs = { { id = 1 } }
    state.user = { id = 'x' }
    local api_cleared = false
    stub_module('azure_pr.api', {
      clear_cache = function()
        api_cleared = true
      end,
    })
    local orig = vim.notify
    vim.notify = function() end
    vim.cmd 'AzurePR clear_cache'
    vim.notify = orig
    eq({}, state.prs)
    eq(nil, state.user)
    truthy(api_cleared)
  end)
end)

describe('health', function()
  it('loads and exposes check()', function()
    local health = require 'azure_pr.health'
    eq('function', type(health.check))
  end)
  it('runs without errors', function()
    azure.setup { organization = 'o', project = 'p', pat = 'secret-pat-value' }
    local ok, err = pcall(vim.cmd, 'checkhealth azure_pr')
    truthy(ok, err)
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    contains(text, 'azure_pr')
    falsy(text:find('secret-pat-value', 1, true), 'PAT printed in health output')
    contains(text, 'organization=o')
    vim.cmd 'bwipeout!'
    azure.setup {}
  end)
end)
