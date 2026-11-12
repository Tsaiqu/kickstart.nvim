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
