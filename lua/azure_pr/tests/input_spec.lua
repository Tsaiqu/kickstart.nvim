---@diagnostic disable: duplicate-set-field, need-check-nil, param-type-mismatch, assign-type-mismatch, redundant-parameter, cast-local-type, missing-parameter
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

local function float_count()
  local n = 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= '' then
      n = n + 1
    end
  end
  return n
end

local function setup()
  reset_modules()
  vim.cmd 'stopinsert'
  -- clean up leftovers from a previously failed test
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= '' then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  vim.wait(20)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match '^azure%-pr://comment/' then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  return require 'azure_pr.ui.input'
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

describe('ui.input', function()
  it('opens a float with acwrite buffer, name, filetype and initial text', function()
    local input = setup()
    local h = input.open({ title = 'Reply', initial = 'hello\r\nworld' }, function() end)
    truthy(vim.api.nvim_win_is_valid(h.win))
    eq(h.win, vim.api.nvim_get_current_win())
    eq('acwrite', vim.bo[h.buf].buftype)
    eq('markdown', vim.bo[h.buf].filetype)
    truthy(vim.api.nvim_buf_get_name(h.buf):match '^azure%-pr://comment/%d+$', 'buffer name')
    eq({ 'hello', 'world' }, vim.api.nvim_buf_get_lines(h.buf, 0, -1, false))
    local cfg = vim.api.nvim_win_get_config(h.win)
    eq('editor', cfg.relative)
    truthy(cfg.width <= 100)
    h.cancel()
    eq(0, float_count())
  end)

  it('<C-s> submits trimmed text and cleans up', function()
    local input = setup()
    local got
    local h = input.open({ title = 'Comment' }, function(text)
      got = text
    end)
    vim.api.nvim_buf_set_lines(h.buf, 0, -1, false, { 'draft' })
    feed '<Esc><Esc>'
    -- <Esc> is not mapped: leaving insert mode twice must keep the draft
    eq(nil, got)
    truthy(vim.api.nvim_buf_is_valid(h.buf), 'esc keeps buffer')
    truthy(vim.api.nvim_win_is_valid(h.win), 'esc keeps window')
    vim.api.nvim_buf_set_lines(h.buf, 0, -1, false, { '', '  first line', 'second  ', '' })
    vim.cmd 'stopinsert'
    feed '<C-s>'
    eq('first line\nsecond', got)
    falsy(vim.api.nvim_win_is_valid(h.win), 'window closed')
    falsy(vim.api.nvim_buf_is_valid(h.buf), 'buffer wiped')
    eq(0, float_count())
  end)

  it('<C-s> works from insert mode', function()
    local input = setup()
    local got
    local h = input.open({}, function(text)
      got = text
    end)
    feed 'ityped<C-s>'
    eq('typed', got)
    falsy(vim.api.nvim_buf_is_valid(h.buf))
  end)

  it(':w submits via BufWriteCmd', function()
    local input = setup()
    local got
    local h = input.open({}, function(text)
      got = text
    end)
    vim.api.nvim_buf_set_lines(h.buf, 0, -1, false, { 'via write' })
    vim.cmd 'write'
    truthy(wait_for(function()
      return got ~= nil
    end))
    eq('via write', got)
    falsy(vim.api.nvim_win_is_valid(h.win))
    falsy(vim.api.nvim_buf_is_valid(h.buf))
  end)

  it(':wq submits and does not close the other window', function()
    local input = setup()
    local wins_before = #vim.api.nvim_list_wins()
    local got
    local h = input.open({}, function(text)
      got = text
    end)
    vim.api.nvim_buf_set_lines(h.buf, 0, -1, false, { 'wq text' })
    vim.cmd 'wq'
    truthy(wait_for(function()
      return got ~= nil
    end))
    eq('wq text', got)
    eq(wins_before, #vim.api.nvim_list_wins())
    falsy(vim.api.nvim_buf_is_valid(h.buf))
  end)

  it('empty content notifies and keeps editor open', function()
    local input = setup()
    local msgs, restore = silence_notify()
    local called = false
    local h = input.open({}, function()
      called = true
    end)
    vim.api.nvim_buf_set_lines(h.buf, 0, -1, false, { '   ', '' })
    h.submit()
    vim.cmd 'write'
    vim.wait(50)
    restore()
    falsy(called)
    eq(2, #msgs)
    truthy(vim.api.nvim_win_is_valid(h.win))
    h.cancel()
    falsy(vim.api.nvim_buf_is_valid(h.buf))
  end)

  it('q cancels, calls on_cancel, not on_submit', function()
    local input = setup()
    local submitted, cancelled = false, false
    local h = input.open({
      on_cancel = function()
        cancelled = true
      end,
    }, function()
      submitted = true
    end)
    vim.cmd 'stopinsert'
    feed 'q'
    falsy(submitted)
    truthy(cancelled)
    falsy(vim.api.nvim_win_is_valid(h.win))
    falsy(vim.api.nvim_buf_is_valid(h.buf))
  end)

  it('q on a changed draft asks for confirmation and stashes the text', function()
    local input = setup()
    local _, restore = silence_notify()
    local orig_select = vim.ui.select
    local answer, prompts = 'No', {}
    vim.ui.select = function(_, o, cb)
      table.insert(prompts, o.prompt)
      cb(answer)
    end
    local cancelled = false
    local h = input.open({
      on_cancel = function()
        cancelled = true
      end,
    }, function() end)
    vim.api.nvim_buf_set_lines(h.buf, 0, -1, false, { 'long review text' })
    vim.cmd 'stopinsert'
    feed 'q'
    eq({ 'Discard comment?' }, prompts)
    falsy(cancelled)
    truthy(vim.api.nvim_win_is_valid(h.win), 'No keeps the editor')
    vim.fn.setreg('"', '')
    answer = 'Yes'
    feed 'q'
    vim.ui.select = orig_select
    restore()
    truthy(cancelled)
    falsy(vim.api.nvim_buf_is_valid(h.buf))
    eq('long review text', vim.fn.getreg '"')
  end)

  it('q on unchanged initial text cancels without asking', function()
    local input = setup()
    local orig_select = vim.ui.select
    local asked = false
    vim.ui.select = function(_, _, cb)
      asked = true
      cb 'No'
    end
    local h = input.open({ initial = 'same' }, function() end)
    vim.cmd 'stopinsert'
    feed 'q'
    vim.ui.select = orig_select
    falsy(asked)
    falsy(vim.api.nvim_buf_is_valid(h.buf))
  end)

  it(':q on a modified buffer closes without error and counts as cancel', function()
    local input = setup()
    local submitted, cancelled = false, false
    local h = input.open({
      on_cancel = function()
        cancelled = true
      end,
    }, function()
      submitted = true
    end)
    vim.api.nvim_buf_set_lines(h.buf, 0, -1, false, { 'unsaved' })
    truthy(vim.bo[h.buf].modified)
    local ok, err = pcall(vim.cmd, 'quit')
    truthy(ok, tostring(err))
    truthy(wait_for(function()
      return cancelled
    end))
    falsy(submitted)
    falsy(vim.api.nvim_win_is_valid(h.win))
    falsy(vim.api.nvim_buf_is_valid(h.buf))
    eq(0, float_count())
  end)

  it('nvim_win_close from outside counts as cancel and wipes buffer', function()
    local input = setup()
    local cancelled = false
    local h = input.open({
      on_cancel = function()
        cancelled = true
      end,
    }, function() end)
    vim.api.nvim_win_close(h.win, true)
    truthy(wait_for(function()
      return cancelled
    end))
    falsy(vim.api.nvim_buf_is_valid(h.buf))
  end)

  it('confirm maps Yes/No', function()
    local input = setup()
    local orig = vim.ui.select
    local answers = { 'Yes', 'No', nil }
    local i = 0
    local seen_items
    vim.ui.select = function(items, _, cb)
      seen_items = items
      i = i + 1
      cb(answers[i])
    end
    local results = {}
    for _ = 1, 3 do
      input.confirm('Sure?', function(ok)
        table.insert(results, ok)
      end)
    end
    vim.ui.select = orig
    eq({ 'Yes', 'No' }, seen_items)
    eq({ true, false, false }, results)
  end)
end)
