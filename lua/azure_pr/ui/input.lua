-- Floating multi-line comment editor and a Yes/No confirm helper.
--
-- Submit: `:w` (BufWriteCmd, buftype=acwrite), `:wq`/`:x`, or <C-s> (normal + insert).
-- Cancel: `q` in normal mode (asks "Discard comment?" when the text was changed), or closing the
-- window any other way (`:q`, `:close`, ...). <Esc> is deliberately NOT mapped, so the usual
-- "<Esc><Esc>" habit never throws a draft away. The buffer is always wiped when the editor closes;
-- a changed, non-empty draft that gets discarded is kept in the unnamed register (`""`).
local M = {}

local DEFAULT_FOOTER = '<C-s>/:w submit · q cancel'

local counter = 0

local function notify(msg, level)
  local ok, util = pcall(require, 'azure_pr.util')
  if ok and type(util) == 'table' and util.notify then
    util.notify(msg, level)
  else
    vim.notify(msg, level, { title = 'Azure PR' })
  end
end

local function trim(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

---@param initial string|nil
---@return string[]
local function initial_lines(initial)
  if not initial or initial == '' then
    return { '' }
  end
  return vim.split((initial:gsub('\r\n', '\n')), '\n', { plain = true })
end

---@param n_lines integer
local function geometry(n_lines)
  local cols, lines = vim.o.columns, vim.o.lines
  local width = math.min(100, math.floor(cols * 0.8))
  width = math.max(math.min(20, cols - 2), width)
  local max_h = math.max(1, lines - 4)
  local height = math.max(math.min(12, max_h), math.floor(lines * 0.4))
  -- grow for long initial content, but never beyond the screen
  height = math.min(math.max(height, n_lines + 1), max_h)
  local row = math.max(0, math.floor((lines - height) / 2) - 1)
  local col = math.max(0, math.floor((cols - width) / 2))
  return { width = width, height = height, row = row, col = col }
end

---@class AzurePRInputOpts
---@field title string|nil        window title
---@field initial string|nil      initial buffer content
---@field filetype string|nil     defaults to 'markdown'
---@field footer string|nil       footer hint (defaults to '<C-s>/:w submit · q cancel')
---@field on_cancel fun()|nil     called when the editor is closed without submitting
---@field no_insert boolean|nil  stay in normal mode (editor reopened after a failed send)

---@class AzurePRInputHandle
---@field buf integer
---@field win integer
---@field submit fun()   submit the current content (same as <C-s>)
---@field cancel fun()   close without submitting (same as q)

--- Open a floating editor. `on_submit(text)` receives the trimmed, non-empty text.
---@param opts AzurePRInputOpts|nil
---@param on_submit fun(text: string)
---@return AzurePRInputHandle
function M.open(opts, on_submit)
  opts = opts or {}
  counter = counter + 1

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  -- NOTE: spec says `azure_pr://comment/<n>`, but Neovim only treats `[a-zA-Z0-9+.-]+://` as a URL
  -- scheme; with an underscore the name gets expanded to `<cwd>/azure_pr://...`. Use `azure-pr://`.
  while not pcall(vim.api.nvim_buf_set_name, buf, 'azure-pr://comment/' .. counter) do
    counter = counter + 1
  end
  local init = initial_lines(opts.initial)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, init)
  vim.bo[buf].filetype = opts.filetype or 'markdown'
  vim.bo[buf].modified = false

  local g = geometry(#init)
  local title = opts.title and (' ' .. opts.title .. ' ') or ' Comment '
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = g.width,
    height = g.height,
    row = g.row,
    col = g.col,
    style = 'minimal',
    border = 'rounded',
    title = title,
    title_pos = 'center',
    footer = ' ' .. (opts.footer or DEFAULT_FOOTER) .. ' ',
    footer_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local group = vim.api.nvim_create_augroup('azure_pr_input_' .. counter, { clear = true })
  local done = false
  local pending_text = nil -- set by BufWriteCmd, delivered on the next tick

  local function get_text()
    if not vim.api.nvim_buf_is_valid(buf) then
      return ''
    end
    return trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
  end

  ---@param kind 'submit'|'cancel'
  ---@param text string|nil
  local function finish(kind, text)
    if done then
      return
    end
    done = true
    pcall(vim.api.nvim_del_augroup_by_id, group)
    if vim.fn.mode():match '^[iR]' then
      vim.cmd.stopinsert()
    end
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    if kind == 'submit' then
      if on_submit then
        on_submit(text --[[@as string]])
      end
    elseif opts.on_cancel then
      opts.on_cancel()
    end
  end

  local function submit()
    if done then
      return
    end
    local text = get_text()
    if text == '' then
      notify('Comment is empty – nothing submitted', vim.log.levels.WARN)
      return
    end
    finish('submit', text)
  end

  --- Text differs from the initial content and is not empty?
  local function dirty()
    local text = get_text()
    return text ~= '' and text ~= trim((opts.initial or ''):gsub('\r\n', '\n'))
  end

  -- keep a discarded draft recoverable
  local function stash_draft()
    if not done and dirty() then
      pcall(vim.fn.setreg, '"', get_text())
      notify('Discarded comment saved to register "', vim.log.levels.INFO)
    end
  end

  local function cancel()
    stash_draft()
    finish 'cancel'
  end

  -- `q`: confirm first when there is a draft worth keeping
  local function cancel_interactive()
    if done then
      return
    end
    if not dirty() then
      return cancel()
    end
    M.confirm('Discard comment?', function(yes)
      if yes then
        cancel()
      end
    end)
  end

  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = buf,
    callback = function()
      local text = get_text()
      if text == '' then
        notify('Comment is empty – nothing submitted', vim.log.levels.WARN)
        return
      end
      vim.bo[buf].modified = false
      -- Deleting the buffer from inside its own BufWriteCmd is unsafe, and for `:wq`/`:x`
      -- the quit part still has to run against this window, so defer the actual close.
      pending_text = text
      vim.schedule(function()
        finish('submit', text)
      end)
    end,
  })

  -- Allow `:q` on a modified buffer without E37: closing the window means "cancel".
  vim.api.nvim_create_autocmd('QuitPre', {
    group = group,
    buffer = buf,
    callback = function()
      if vim.api.nvim_buf_is_valid(buf) then
        if not pending_text then
          stash_draft()
        end
        vim.bo[buf].modified = false
      end
    end,
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(win),
    callback = function()
      -- The window is going away (e.g. :q, :close, <C-w>o). Defer: we are inside an autocmd.
      vim.schedule(function()
        if pending_text then
          finish('submit', pending_text)
        else
          finish 'cancel'
        end
      end)
    end,
  })

  -- Buffer wiped by some other means (e.g. :bwipeout) while the window survived elsewhere.
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if pending_text then
          finish('submit', pending_text)
        else
          finish 'cancel'
        end
      end)
    end,
  })

  local map_opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit, vim.tbl_extend('force', map_opts, { desc = 'Azure PR: submit comment' }))
  vim.keymap.set('n', 'q', cancel_interactive, vim.tbl_extend('force', map_opts, { desc = 'Azure PR: cancel comment' }))

  if opts.initial and opts.initial ~= '' then
    -- editing existing text: put the cursor at the very end
    local last = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, win, { last, #init[#init] })
    if not opts.no_insert then
      vim.cmd 'startinsert!'
    end
  elseif not opts.no_insert then
    vim.cmd.startinsert()
  end

  return { buf = buf, win = win, submit = submit, cancel = cancel }
end

--- Ask a Yes/No question. `cb(true)` only when "Yes" was chosen.
---@param prompt string
---@param cb fun(confirmed: boolean)
function M.confirm(prompt, cb)
  vim.ui.select({ 'Yes', 'No' }, { prompt = prompt }, function(choice)
    cb(choice == 'Yes')
  end)
end

return M
