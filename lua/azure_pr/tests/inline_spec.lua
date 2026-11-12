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
end)
