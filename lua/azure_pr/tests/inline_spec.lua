---@diagnostic disable: duplicate-set-field, need-check-nil, param-type-mismatch, assign-type-mismatch, redundant-parameter, cast-local-type, missing-parameter
local inline = require 'azure_pr.ui.inline'

local function thread(id, line, opts)
  opts = opts or {}
  return {
    id = id,
    status = opts.status or 'active',
    file_path = opts.file_path or '/src/a.py',
    line = line,
    end_line = line,
    side = opts.side or 'right',
    is_system = opts.is_system or false,
    comments = opts.comments or {
      { id = 1, parent_id = 0, author = { name = 'Jan Kowalski' }, content = 'VAT liczymy\nz netto', type = 'text' },
    },
  }
end

local function scratch(n)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, n or 50 do
    lines[i] = 'line ' .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  return buf
end

local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, inline.ns, 0, -1, { details = true })
end

local OPTS = { side = 'right', path = '/src/a.py' }

describe('inline.place', function()
  it('places a sign and hint on the thread line', function()
    local buf = scratch()
    inline.place(buf, { id = 7 }, { thread(1, 43) }, OPTS)
    local m = marks(buf)
    eq(1, #m)
    eq(42, m[1][2])
    truthy(m[1][4].sign_text ~= nil)
    eq('AzurePRThreadActive', m[1][4].sign_hl_group)
    contains(m[1][4].virt_text[1][1], 'Jan Kowalski: VAT liczymy')
    eq('eol', m[1][4].virt_text_pos)
    eq(7, vim.b[buf].azure_pr_inline.pr_id)
  end)

  it('skips threads of the other side, other files and system threads', function()
    local buf = scratch()
    inline.place(buf, { id = 7 }, {
      thread(1, 5, { side = 'left' }),
      thread(2, 6, { file_path = '/src/b.py' }),
      thread(3, 7, { is_system = true }),
      (function() local t = thread(4, 8); t.side = nil; return t end)(),
    }, OPTS)
    eq(0, #marks(buf))
  end)

  it('matches paths after normalisation', function()
    local buf = scratch()
    inline.place(buf, { id = 7 }, { thread(1, 3) }, { side = 'right', path = 'src\\a.py' })
    eq(1, #marks(buf))
  end)

  it('clamps a line beyond the buffer', function()
    local buf = scratch()
    inline.place(buf, { id = 7 }, { thread(1, 200) }, OPTS)
    eq(49, marks(buf)[1][2])
  end)

  it('dims resolved threads', function()
    local buf = scratch()
    inline.place(buf, { id = 7 }, { thread(1, 4, { status = 'fixed' }) }, OPTS)
    local d = marks(buf)[1][4]
    eq('AzurePRInlineResolved', d.sign_hl_group)
    eq('AzurePRInlineResolved', d.virt_text[1][2])
  end)

  it('merges threads on the same line into one mark', function()
    local buf = scratch()
    inline.place(buf, { id = 7 }, { thread(1, 10), thread(2, 10) }, OPTS)
    local m = marks(buf)
    eq(1, #m)
    contains(m[1][4].virt_text[1][1], '[+1 threads]')
    eq(2, #inline.threads_at(buf, 10))
    eq(0, #inline.threads_at(buf, 11))
  end)

  it('re-placing clears old marks', function()
    local buf = scratch()
    inline.place(buf, { id = 7 }, { thread(1, 10) }, OPTS)
    inline.place(buf, { id = 7 }, { thread(1, 12) }, OPTS)
    local m = marks(buf)
    eq(1, #m)
    eq(11, m[1][2])
  end)
end)

describe('inline.hint', function()
  it('appends reply count', function()
    local t = thread(1, 1, {
      comments = {
        { id = 1, parent_id = 0, author = { name = 'A' }, content = 'hello', type = 'text' },
        { id = 2, parent_id = 1, author = { name = 'B' }, content = 'x', type = 'text' },
        { id = 3, parent_id = 1, author = { name = 'B' }, content = 'del', type = 'text', is_deleted = true },
        { id = 4, parent_id = 1, author = { name = 'B' }, content = 'sys', type = 'system' },
      },
    })
    eq('A: hello (+1)', inline.hint(t, 80))
  end)

  it('truncates to max_width with an ellipsis', function()
    local t = thread(1, 1, {
      comments = { { id = 1, parent_id = 0, author = { name = 'A' }, content = string.rep('word ', 40), type = 'text' } },
    })
    local h = inline.hint(t, 20)
    truthy(vim.fn.strdisplaywidth(h) <= 20)
    contains(h, '…')
  end)
end)

describe('inline.jump', function()
  it('cycles through thread lines with wrap', function()
    local buf = scratch()
    inline.place(buf, { id = 7 }, { thread(1, 43), thread(2, 10) }, OPTS)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    inline.jump(buf, 1)
    eq(10, vim.api.nvim_win_get_cursor(0)[1])
    inline.jump(buf, 1)
    eq(43, vim.api.nvim_win_get_cursor(0)[1])
    inline.jump(buf, 1)
    eq(10, vim.api.nvim_win_get_cursor(0)[1])
    inline.jump(buf, -1)
    eq(43, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it('does nothing without threads', function()
    local buf = scratch()
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    inline.jump(buf, 1)
    eq(5, vim.api.nvim_win_get_cursor(0)[1])
  end)
end)

describe('inline marks after buffer edits', function()
  it('threads_at and jump follow the extmark when lines are inserted above', function()
    local buf = scratch()
    inline.place(buf, { id = 7 }, { thread(1, 10), thread(2, 30) }, OPTS)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'new' })
    eq(0, #inline.threads_at(buf, 10))
    eq(1, #inline.threads_at(buf, 11))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    inline.jump(buf, 1)
    eq(11, vim.api.nvim_win_get_cursor(0)[1])
    inline.jump(buf, 1)
    eq(31, vim.api.nvim_win_get_cursor(0)[1])
  end)
end)

describe('inline keymaps and detach', function()
  local function has_map(buf, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      if m.lhs == lhs then
        return true
      end
    end
    return false
  end

  it('sets buffer maps once and detach removes everything', function()
    local buf = scratch()
    inline.place(buf, { id = 7 }, { thread(1, 10) }, OPTS)
    inline.place(buf, { id = 7 }, { thread(1, 10) }, OPTS)
    truthy(has_map(buf, ']t'))
    truthy(has_map(buf, '[t'))
    inline.detach(buf)
    falsy(has_map(buf, ']t'))
    falsy(has_map(buf, '[t'))
    eq(0, #marks(buf))
    eq(0, #inline.threads_at(buf, 10))
    eq(nil, vim.b[buf].azure_pr_inline)
  end)

  it('keeps a pre-existing buffer-local map untouched', function()
    local buf = scratch()
    vim.keymap.set('n', ']t', 'ix<Esc>', { buffer = buf })
    inline.place(buf, { id = 7 }, { thread(1, 10) }, OPTS)
    local m = vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg(']t', 'n', false, true)
    end)
    eq('ix<Esc>', m.rhs)
    truthy(has_map(buf, '[t'))
    inline.detach(buf)
    truthy(has_map(buf, ']t'))
    falsy(has_map(buf, '[t'))
  end)
end)

describe('inline.show_thread', function()
  local store = require 'azure_pr.threads_store'
  local actions = require 'azure_pr.actions'
  local PR = { id = 7, repository = { id = 'r' } }

  local function float_wins()
    local out = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= '' then
        out[#out + 1] = w
      end
    end
    return out
  end
  local function close_floats()
    for _, w in ipairs(float_wins()) do
      pcall(vim.api.nvim_win_close, w, true)
    end
  end

  it('opens a float with author and content', function()
    local buf = scratch()
    inline.place(buf, PR, { thread(1, 3) }, OPTS)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    inline.show_thread()
    local fl = float_wins()
    eq(1, #fl)
    local fb = vim.api.nvim_win_get_buf(fl[1])
    local text = table.concat(vim.api.nvim_buf_get_lines(fb, 0, -1, false), '\n')
    contains(text, 'Jan Kowalski')
    contains(text, 'VAT liczymy')
    falsy(vim.bo[fb].modifiable)
    close_floats()
  end)

  it('warns when no thread on the line', function()
    local buf = scratch()
    inline.place(buf, PR, { thread(1, 3) }, OPTS)
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    local orig = vim.notify
    local got
    vim.notify = function(msg, level)
      got = { msg, level }
    end
    inline.show_thread()
    vim.notify = orig
    eq('No comment thread on this line', got[1])
    eq(vim.log.levels.WARN, got[2])
    eq(0, #float_wins())
  end)

  it('r and s call actions with thread and PR', function()
    local buf = scratch()
    inline.place(buf, PR, { thread(11, 3) }, OPTS)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    inline.show_thread()
    local o_reply, o_status = actions.reply, actions.set_thread_status
    local calls = {}
    actions.reply = function(pr, t, c, cb)
      calls.reply = { pr, t, c, cb }
    end
    actions.set_thread_status = function(pr, t, cb)
      calls.status = { pr, t, cb }
    end
    local fw = float_wins()[1]
    local fb = vim.api.nvim_win_get_buf(fw)
    vim.api.nvim_win_set_cursor(fw, { 2, 0 })
    vim.api.nvim_buf_call(fb, function()
      vim.cmd 'normal r'
    end)
    eq(11, calls.reply[2].id)
    eq(7, calls.reply[1].id)
    truthy(calls.reply[3] ~= nil, 'comment under cursor')
    vim.api.nvim_buf_call(fb, function()
      vim.cmd 'normal s'
    end)
    eq(11, calls.status[2].id)
    actions.reply, actions.set_thread_status = o_reply, o_status
    close_floats()
  end)

  it('re-places markers when the store changes', function()
    local buf = scratch()
    inline.place(buf, PR, { thread(1, 3) }, OPTS)
    eq('AzurePRThreadActive', marks(buf)[1][4].sign_hl_group)
    store.set(PR, { thread(1, 3, { status = 'fixed' }) })
    eq('AzurePRInlineResolved', marks(buf)[1][4].sign_hl_group)
    store.clear()
  end)
end)

describe('inline.show_thread fallback pr', function()
  local store = require 'azure_pr.threads_store'
  it('uses the pr given to place when the store has no entry', function()
    local actions = require 'azure_pr.actions'
    local o_reply = actions.reply
    local got
    actions.reply = function(pr, _, _, _)
      got = pr
    end
    local buf = scratch()
    local pr = { id = 987001, repository = { name = 'web' } }
    store.clear()
    inline.place(buf, pr, { thread(11, 3) }, OPTS)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    inline.show_thread(buf, 3)
    local fw
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= '' then
        fw = w
      end
    end
    vim.api.nvim_buf_call(vim.api.nvim_win_get_buf(fw), function()
      vim.cmd 'normal r'
    end)
    actions.reply = o_reply
    eq('web', got.repository.name)
    pcall(vim.api.nvim_win_close, fw, true)
  end)
end)

describe('inline auto attach', function()
  local store = require 'azure_pr.threads_store'
  local actions = require 'azure_pr.actions'
  local config = require 'azure_pr.config'
  local state = require 'azure_pr.state'
  local o = {
    git = actions._git,
    cbp = actions.current_branch_pr,
    target = config.resolve_target,
    notify = vim.notify,
    loaded = package.loaded['diffview.lib'],
  }
  local notes, cbp_calls, git_calls, branch
  local AZURE = 'https://dev.azure.com/org/proj/_git/web'

  local function setup(opts)
    opts = opts or {}
    notes, cbp_calls, git_calls, branch = 0, 0, 0, 'feature/x'
    inline._reset_caches()
    store.clear()
    state.diff_views = {}
    vim.notify = function()
      notes = notes + 1
    end
    config.resolve_target = function(cb)
      cb(nil, { organization = 'o', project = 'p' })
    end
    actions._git = function(args, _, cb)
      local key = table.concat(args, ' ')
      git_calls = git_calls + 1
      if opts.no_git then
        return cb(128, '', 'not a git repository')
      end
      if key == 'rev-parse --show-toplevel' then
        return cb(0, '/tmp/repo\n', '')
      elseif key == 'rev-parse --abbrev-ref HEAD' then
        return cb(0, branch .. '\n', '')
      elseif key == 'remote get-url origin' then
        return cb(0, (opts.remote or AZURE) .. '\n', '')
      end
      cb(1, '', 'unexpected ' .. key)
    end
    actions.current_branch_pr = function(cb)
      cbp_calls = cbp_calls + 1
      if opts.pr and branch == opts.pr.source_branch then
        return cb(nil, opts.pr)
      end
      cb 'No active pull request'
    end
  end
  local function teardown()
    actions._git, actions.current_branch_pr, config.resolve_target = o.git, o.cbp, o.target
    vim.notify = o.notify
    package.loaded['diffview.lib'] = o.loaded
    state.diff_views = {}
    store.clear()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find('/tmp/repo/', 1, true) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end

  local function diff_view(buf, symbol)
    local file = { bufnr = buf, path = 'src/a.py', symbol = symbol }
    local win = { file = file }
    local layout = symbol == 'a' and { a = win, b = { file = { bufnr = -1 } } } or { b = win, a = { file = { bufnr = -1 } } }
    package.loaded['diffview.lib'] = {
      get_current_view = function()
        return { tabpage = vim.api.nvim_get_current_tabpage(), cur_entry = { layout = layout } }
      end,
    }
  end

  it('does nothing without a diff_views entry', function()
    setup()
    local buf = scratch()
    diff_view(buf, 'b')
    store.set({ id = 987010 }, { thread(1, 4) })
    inline.attach_diffview_buf(buf)
    eq(0, #marks(buf))
    eq(0, cbp_calls)
    teardown()
  end)

  it('attach_diffview_buf places right-side threads on the b buffer', function()
    setup()
    local buf = scratch()
    diff_view(buf, 'b')
    local pr = { id = 987011 }
    state.diff_views[vim.api.nvim_get_current_tabpage()] = { pr = pr, revs = {} }
    store.set(pr, { thread(1, 4), thread(2, 6, { side = 'left' }) })
    inline.attach_diffview_buf(buf)
    local m = marks(buf)
    eq(1, #m)
    eq(3, m[1][2])
    teardown()
  end)

  it('attach_diffview_buf shows left threads on the a buffer', function()
    setup()
    local buf = scratch()
    diff_view(buf, 'a')
    local pr = { id = 987012 }
    state.diff_views[vim.api.nvim_get_current_tabpage()] = { pr = pr, revs = {} }
    store.set(pr, { thread(1, 4), thread(2, 6, { side = 'left' }) })
    inline.attach_diffview_buf(buf)
    local m = marks(buf)
    eq(1, #m)
    eq(5, m[1][2])
    teardown()
  end)

  it('prunes diff_views of closed tabs', function()
    setup()
    state.diff_views[99999] = { pr = { id = 1 }, revs = {} }
    local cur = vim.api.nvim_get_current_tabpage()
    state.diff_views[cur] = { pr = { id = 2 }, revs = {} }
    package.loaded['diffview.lib'] = {
      tabpage_to_view = function()
        return {}
      end,
    }
    inline._prune_diff_views()
    eq(nil, state.diff_views[99999])
    truthy(state.diff_views[cur])
    teardown()
  end)

  it('attach_file_buf stays silent when no PR is found', function()
    setup()
    local buf = scratch()
    vim.bo[buf].buftype = ''
    vim.api.nvim_buf_set_name(buf, '/tmp/repo/src/a.py')
    inline.attach_file_buf(buf)
    eq(0, #marks(buf))
    eq(0, notes)
    eq(1, cbp_calls)
    teardown()
  end)

  it('attach_file_buf looks the PR up once per (root, branch)', function()
    setup()
    local buf = scratch()
    vim.bo[buf].buftype = ''
    vim.api.nvim_buf_set_name(buf, '/tmp/repo/src/a.py')
    inline.attach_file_buf(buf)
    local buf2 = scratch()
    vim.bo[buf2].buftype = ''
    vim.api.nvim_buf_set_name(buf2, '/tmp/repo/src/b.py')
    inline.attach_file_buf(buf2)
    eq(1, cbp_calls)
    teardown()
  end)

  it('attach_file_buf places markers when the PR is found (path relative to root)', function()
    local pr = { id = 987013, source_branch = 'feature/x', repository = { name = 'web' } }
    setup { pr = pr }
    store.set(pr, { thread(1, 4) })
    local buf = scratch()
    vim.bo[buf].buftype = ''
    vim.api.nvim_buf_set_name(buf, '/tmp/repo/src/a.py')
    inline.attach_file_buf(buf)
    eq(1, #marks(buf))
    eq('src/a.py', vim.b[buf].azure_pr_inline.path)
    eq(0, notes)
    teardown()
  end)

  local function file_buf(path)
    local buf = scratch()
    vim.bo[buf].buftype = ''
    vim.api.nvim_buf_set_name(buf, path or '/tmp/repo/src/a.py')
    return buf
  end

  it('attach_file_buf skips repositories whose origin is not Azure DevOps', function()
    setup { remote = 'git@github.com:me/web.git', pr = { id = 987014, source_branch = 'feature/x', repository = { name = 'web' } } }
    local buf = file_buf()
    inline.attach_file_buf(buf)
    eq(0, cbp_calls)
    eq(0, #marks(buf))
    teardown()
  end)

  it('attach_file_buf ignores a PR from a different repository', function()
    local pr = { id = 987015, source_branch = 'feature/x', repository = { name = 'other' } }
    setup { pr = pr }
    store.set(pr, { thread(1, 4) })
    local buf = file_buf()
    inline.attach_file_buf(buf)
    eq(0, #marks(buf))
    teardown()
  end)

  it('caches git failures: two attaches in a non-git dir run git once', function()
    setup { no_git = true }
    local b1 = file_buf '/tmp/repo/src/a.py'
    inline.attach_file_buf(b1)
    local b2 = file_buf '/tmp/repo/src/b.py'
    inline.attach_file_buf(b2)
    eq(1, git_calls)
    eq(0, cbp_calls)
    teardown()
  end)

  it('attach_file_buf drops markers after the branch changes', function()
    local pr = { id = 987016, source_branch = 'feature/x', repository = { name = 'web' } }
    setup { pr = pr }
    store.set(pr, { thread(1, 4) })
    local buf = file_buf()
    inline.attach_file_buf(buf)
    eq(1, #marks(buf))
    branch = 'other'
    inline._reset_caches_git_only()
    inline.attach_file_buf(buf)
    eq(0, #marks(buf))
    eq(nil, vim.b[buf].azure_pr_inline)
    teardown()
  end)
end)
