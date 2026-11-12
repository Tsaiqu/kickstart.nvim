-- Inline PR thread markers (sign + end-of-line hint) in code buffers and ]t/[t navigation.
local frame = require 'azure_pr.ui.frame'
local hl = require 'azure_pr.ui.highlights'

local M = {}

M.ns = vim.api.nvim_create_namespace 'azure_pr_inline'

local HINT_WIDTH = 80

--- Per-buffer state: { marks = { { lnum, thread_ids, threads } }, keys = { lhs... } }
local state = {}

local function is_open(status)
  return status == 'active' or status == 'pending' or status == 'unknown'
end

local function visible_text_comments(thread)
  local out = {}
  for _, c in ipairs(thread.comments or {}) do
    if not c.is_deleted and (c.type == nil or c.type == 'text') then
      out[#out + 1] = c
    end
  end
  return out
end

local function truncate(s, max)
  if frame.dw(s) <= max then
    return s
  end
  local ell = hl.icons().ellipsis
  local out, w = {}, 0
  for _, ch in ipairs(vim.fn.split(s, '\\zs')) do
    local cw = frame.dw(ch)
    if w + cw > max - frame.dw(ell) then
      break
    end
    out[#out + 1] = ch
    w = w + cw
  end
  return table.concat(out) .. ell
end

--- "<author>: <first line of first comment> (+N)" cut to `max_width` display cells.
---@param thread table
---@param max_width integer
---@return string
function M.hint(thread, max_width)
  local comments = visible_text_comments(thread)
  local first = comments[1]
  if not first then
    return ''
  end
  local author = first.author and first.author.name or '?'
  local line = vim.split(first.content or '', '\n', { plain = true })[1] or ''
  line = vim.trim(line)
  local suffix = #comments > 1 and (' (+' .. (#comments - 1) .. ')') or ''
  local head = truncate(author .. ': ' .. line, math.max(max_width - frame.dw(suffix), 1))
  return head .. suffix
end

local function lhs_list(v)
  if not v then
    return {}
  end
  if type(v) == 'string' then
    return { v }
  end
  return v
end

local function nav_keys()
  local ok, config = pcall(require, 'azure_pr.config')
  local km = {}
  if ok then
    local defaults = config.defaults and config.defaults.keymaps and config.defaults.keymaps.detail or {}
    local okc, cur = pcall(config.get)
    local user = okc and type(cur) == 'table' and cur.keymaps and cur.keymaps.detail or {}
    km = vim.tbl_extend('force', defaults, user)
  end
  return { next = lhs_list(km.next_thread), prev = lhs_list(km.prev_thread) }
end

local function use_icons()
  local ok, config = pcall(require, 'azure_pr.config')
  if ok then
    local okc, cur = pcall(config.get)
    if okc and type(cur) == 'table' and cur.icons ~= nil then
      return cur.icons and true or false
    end
  end
  return nil
end

--- Remove marks, keymaps and stored data of `buf`.
---@param buf integer
function M.detach(buf)
  local st = state[buf]
  state[buf] = nil
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, buf, M.ns, 0, -1)
  if st then
    for _, lhs in ipairs(st.keys) do
      pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
    end
  end
  pcall(function()
    vim.b[buf].azure_pr_inline = nil
  end)
end

local function set_keys(buf, st)
  if st.keys then
    return
  end
  st.keys = {}
  local keys = nav_keys()
  for _, spec in ipairs { { keys.next, 1, 'Next thread' }, { keys.prev, -1, 'Previous thread' } } do
    for _, lhs in ipairs(spec[1]) do
      -- never override (or later delete) a buffer-local mapping we did not create
      local existing = vim.api.nvim_buf_call(buf, function()
        return vim.fn.maparg(lhs, 'n', false, true)
      end)
      if not (type(existing) == 'table' and existing.buffer == 1) then
        vim.keymap.set('n', lhs, function()
          M.jump(buf, spec[2])
        end, { buffer = buf, silent = true, desc = 'Azure PR: ' .. spec[3] })
        st.keys[#st.keys + 1] = lhs
      end
    end
  end
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      state[buf] = nil
    end,
  })
end

---@param buf integer
---@param pr table
---@param threads table[]
---@param opts { side: string, path: string }
function M.place(buf, pr, threads, opts)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  local old = state[buf]
  local st = { marks = {}, keys = old and old.keys or nil }
  state[buf] = st

  local icons = hl.icons(use_icons())
  local api = require 'azure_pr.api'
  local want = api._thread_file_path(opts.path)
  local count = vim.api.nvim_buf_line_count(buf)

  local by_line, order = {}, {}
  for _, t in ipairs(threads or {}) do
    if
      not t.is_system
      and t.file_path
      and t.line
      and t.side
      and t.side == opts.side
      and api._thread_file_path(t.file_path) == want
    then
      local lnum = math.max(math.min(t.line, count), 1)
      if not by_line[lnum] then
        by_line[lnum] = {}
        order[#order + 1] = lnum
      end
      table.insert(by_line[lnum], t)
    end
  end
  table.sort(order)

  for _, lnum in ipairs(order) do
    local group = by_line[lnum]
    local open = false
    local ids = {}
    for _, t in ipairs(group) do
      open = open or is_open(t.status)
      ids[#ids + 1] = t.id
    end
    local text = M.hint(group[1], HINT_WIDTH)
    if #group > 1 then
      text = text .. ' [+' .. (#group - 1) .. ' threads]'
    end
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, lnum - 1, 0, {
      sign_text = open and icons.thread_active or icons.thread_resolved,
      sign_hl_group = open and 'AzurePRThreadActive' or 'AzurePRInlineResolved',
      virt_text = { { '  ' .. text, open and 'AzurePRInlineHint' or 'AzurePRInlineResolved' } },
      virt_text_pos = 'eol',
    })
    st.marks[#st.marks + 1] = { lnum = lnum, thread_ids = ids, threads = group }
  end

  vim.b[buf].azure_pr_inline = { pr_id = pr and pr.id, side = opts.side, path = opts.path }
  set_keys(buf, st)
  M._ensure_refresh_autocmd()
end

local refresh_registered = false

--- Re-place markers in every buffer attached to the PR whose threads changed in the store.
function M._ensure_refresh_autocmd()
  if refresh_registered then
    return
  end
  refresh_registered = true
  vim.api.nvim_create_autocmd('User', {
    group = vim.api.nvim_create_augroup('AzurePRInlineRefresh', { clear = true }),
    pattern = 'AzurePRThreadsChanged',
    callback = function(ev)
      local pr_id = ev.data and ev.data.pr_id
      local entry = pr_id ~= nil and require('azure_pr.threads_store').get(pr_id) or nil
      if not entry then
        return
      end
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local ok, info = pcall(function()
          return vim.b[buf].azure_pr_inline
        end)
        if ok and type(info) == 'table' and tostring(info.pr_id) == tostring(pr_id) and state[buf] then
          M.place(buf, entry.pr, entry.threads, { side = info.side, path = info.path })
        end
      end
    end,
  })
end

local function inline_keys()
  local defaults = { reply = 'r', status = 's', browser = 'o', close = { 'q', '<Esc>' } }
  local ok, config = pcall(require, 'azure_pr.config')
  if not ok then
    return defaults
  end
  local okc, cur = pcall(config.get)
  local user = okc and type(cur) == 'table' and cur.keymaps and cur.keymaps.inline or {}
  return vim.tbl_extend('force', defaults, user)
end

--- Float with the full thread(s) on `lnum` of `buf` (defaults: current buffer / cursor line).
---@param buf integer|nil
---@param lnum integer|nil
function M.show_thread(buf, lnum)
  buf = buf or vim.api.nvim_get_current_buf()
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local threads = M.threads_at(buf, lnum)
  if #threads == 0 then
    vim.notify('No comment thread on this line', vim.log.levels.WARN)
    return
  end
  local info = vim.b[buf].azure_pr_inline or {}
  local entry = info.pr_id ~= nil and require('azure_pr.threads_store').get(info.pr_id) or nil
  local pr = entry and entry.pr or { id = info.pr_id }

  local render = require 'azure_pr.ui.render'
  local width = math.min(80, vim.o.columns - 4)
  local lines, highlights, items = {}, {}, {}
  local total = 0
  for i, t in ipairs(threads) do
    if i > 1 then
      lines[#lines + 1] = ''
    end
    if #threads > 1 then
      lines[#lines + 1] = ('[%s] thread %d/%d'):format(t.status or 'unknown', i, #threads)
      items[#lines] = { kind = 'thread', thread = t }
      highlights[#highlights + 1] = { #lines - 1, 0, -1, is_open(t.status) and 'AzurePRThreadActive' or 'AzurePRInlineResolved' }
    end
    local res = render.thread_lines(t, { width = width, icons = hl.icons(use_icons()), pr = pr })
    local off = #lines
    for _, l in ipairs(res.lines) do
      lines[#lines + 1] = l
    end
    for _, h in ipairs(res.highlights) do
      highlights[#highlights + 1] = { h[1] + off, h[2], h[3], h[4] }
    end
    for n, item in pairs(res.items) do
      items[n + off] = item
    end
    total = total + #visible_text_comments(t)
  end

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].buftype = 'nofile'
  vim.bo[fbuf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  for _, h in ipairs(highlights) do
    pcall(vim.api.nvim_buf_set_extmark, fbuf, M.ns, h[1], h[2], {
      end_row = h[3] == -1 and h[1] + 1 or h[1],
      end_col = h[3] ~= -1 and h[3] or 0,
      hl_group = h[4],
    })
  end
  vim.bo[fbuf].modifiable = false

  local status = #threads == 1 and (threads[1].status or 'unknown') or (#threads .. ' threads')
  local title = (' %s · %d comment%s '):format(status, total, total == 1 and '' or 's')
  local win = vim.api.nvim_open_win(fbuf, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = math.max(math.min(#lines, 20), 1),
    style = 'minimal',
    border = 'rounded',
    title = title,
    title_pos = 'left',
  })
  vim.wo[win].wrap = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  vim.api.nvim_create_autocmd('WinLeave', { buffer = fbuf, once = true, callback = close })

  local function under_cursor()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local item = items[row]
    -- fall back to the nearest item above (wrapped / blank lines)
    local r = row
    while not item and r > 1 do
      r = r - 1
      item = items[r]
    end
    item = item or items[next(items)]
    local t = item and item.thread or threads[1]
    return t, item and item.kind == 'comment' and item.comment or nil
  end

  local function done(err)
    if not err then
      close()
    end
  end

  local keys = inline_keys()
  local function map(lhss, fn, desc)
    for _, lhs in ipairs(lhs_list(lhss)) do
      vim.keymap.set('n', lhs, fn, { buffer = fbuf, nowait = true, silent = true, desc = 'Azure PR: ' .. desc })
    end
  end
  local actions = require 'azure_pr.actions'
  map(keys.close, close, 'Close thread')
  map(keys.reply, function()
    local t, c = under_cursor()
    actions.reply(pr, t, c, function(err)
      if not err then
        actions.refresh_detail_of(pr)
      end
      done(err)
    end)
  end, 'Reply')
  map(keys.status, function()
    local t = under_cursor()
    actions.set_thread_status(pr, t, function(err)
      if not err then
        actions.refresh_detail_of(pr)
      end
      done(err)
    end)
  end, 'Change thread status')
  map(keys.browser, function()
    actions.open_in_browser(pr)
  end, 'Open PR in browser')
end

--- Threads anchored on `lnum` (1-based).
---@param buf integer
---@param lnum integer
---@return table[]
function M.threads_at(buf, lnum)
  local st = state[buf]
  if not st then
    return {}
  end
  for _, m in ipairs(st.marks) do
    if m.lnum == lnum then
      return m.threads
    end
  end
  return {}
end

--- Move the cursor to the next/previous line with a thread (wraps around).
---@param buf integer
---@param dir integer 1|-1
function M.jump(buf, dir)
  local st = state[buf]
  if not st or #st.marks == 0 then
    return
  end
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    win = vim.api.nvim_get_current_win()
  end
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local n = #st.marks
  local target
  if dir > 0 then
    target = st.marks[1].lnum
    for _, m in ipairs(st.marks) do
      if m.lnum > cur then
        target = m.lnum
        break
      end
    end
  else
    target = st.marks[n].lnum
    for i = n, 1, -1 do
      if st.marks[i].lnum < cur then
        target = st.marks[i].lnum
        break
      end
    end
  end
  vim.api.nvim_win_set_cursor(win, { target, 0 })
end

return M
