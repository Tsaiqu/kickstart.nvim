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
