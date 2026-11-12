-- Code snippets (unified-diff excerpts) for PR comment threads, read from the local git repo.
local M = {}

---@class AzurePRHunkLine
---@field kind ' '|'+'|'-'
---@field text string

---@class AzurePRHunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field lines AzurePRHunkLine[]

---@class AzurePRSnippetRow
---@field kind ' '|'+'|'-'
---@field old integer|nil
---@field new integer|nil
---@field text string
---@field focus boolean

local UNAVAILABLE = 'code unavailable'

local cache = {}
local git_cache = {} -- (kind, rev, path) -> git output; shared by all threads of a file
local git_inflight = {}

function M.clear_cache()
  cache = {}
  git_cache = {}
  git_inflight = {}
end

--- Run a git command once per `key`: successes are cached, concurrent callers share the call.
---@param key string
---@param args string[]
---@param cwd string
---@param cb fun(code: integer, out: string|nil)
local function git_once(key, args, cwd, cb)
  if git_cache[key] then
    return cb(0, git_cache[key])
  end
  if git_inflight[key] then
    table.insert(git_inflight[key], cb)
    return
  end
  git_inflight[key] = { cb }
  require('azure_pr.actions')._git(args, { cwd = cwd }, function(code, out)
    local waiting = git_inflight[key] or {}
    git_inflight[key] = nil
    if code == 0 then
      git_cache[key] = out or ''
    end
    for _, f in ipairs(waiting) do
      f(code, out)
    end
  end)
end

local function detab(s)
  return (s:gsub('\t', '    '))
end

--- Parse `git diff` output into hunks. "\ No newline" markers are skipped.
---@param diff_text string
---@return AzurePRHunk[]
function M.parse_hunks(diff_text)
  local hunks, cur = {}, nil
  for line in (diff_text or ''):gmatch '[^\n]*' do
    local os_, oc, ns, nc = line:match '^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@'
    if os_ then
      cur = {
        old_start = tonumber(os_),
        old_count = oc == '' and 1 or tonumber(oc),
        new_start = tonumber(ns),
        new_count = nc == '' and 1 or tonumber(nc),
        lines = {},
      }
      table.insert(hunks, cur)
    elseif cur then
      local c = line:sub(1, 1)
      if c == ' ' or c == '+' or c == '-' then
        table.insert(cur.lines, { kind = c, text = line:sub(2) })
      end
    end
  end
  return hunks
end

--- Build snippet rows for a thread. For side 'left', `file_lines` is the base version.
---@param thread { line: integer, end_line: integer|nil, side: string|nil }
---@param file_lines string[]
---@param hunks AzurePRHunk[]
---@param opts { context: integer }|nil
---@return AzurePRSnippetRow[]
function M.build(thread, file_lines, hunks, opts)
  local context = opts and opts.context or 2
  local left = thread.side == 'left'
  if not thread.line then
    return {}
  end
  local first = thread.line
  local last = thread.end_line or thread.line
  if last < first then
    first, last = last, first
  end
  local total = #file_lines
  if not first or first < 1 or first > total then
    return {}
  end
  last = math.min(last, total)
  local key = left and 'old' or 'new'

  -- All rows of hunks that touch the range.
  local rows = {}
  for _, h in ipairs(hunks or {}) do
    local hrows, touches = {}, false
    local o, n = h.old_start, h.new_start
    for _, l in ipairs(h.lines) do
      local row = { kind = l.kind, text = detab(l.text), focus = false }
      if l.kind == ' ' then
        row.old, row.new = o, n
        o, n = o + 1, n + 1
      elseif l.kind == '-' then
        row.old = o
        o = o + 1
      else
        row.new = n
        n = n + 1
      end
      local num = row[key]
      if num and num >= first and num <= last then
        row.focus, touches = true, true
      end
      table.insert(hrows, row)
    end
    if touches then
      vim.list_extend(rows, hrows)
    end
  end

  if #rows == 0 then
    for i = math.max(1, first - context), last do
      table.insert(rows, { kind = ' ', old = i, new = i, text = detab(file_lines[i] or ''), focus = i >= first })
    end
    return rows
  end

  local fi, li
  for i, r in ipairs(rows) do
    if r.focus then
      fi = fi or i
      li = i
    end
  end
  local out = {}
  for i = math.max(1, fi - context), li do
    table.insert(out, rows[i])
  end
  return out
end

--- Asynchronously load the snippet rows for `thread` from the local repo.
---@param pr AzurePR
---@param thread table
---@param cwd string
---@param cb fun(rows: AzurePRSnippetRow[]|nil, err: string|nil)
function M.get(pr, thread, cwd, cb)
  local actions = require 'azure_pr.actions'
  local path = (thread.file_path or ''):gsub('^/', '')
  local left = thread.side == 'left'

  actions.resolve_pr_revs(pr, cwd, function(err, revs)
    if err or not revs then
      return cb(nil, UNAVAILABLE)
    end
    local rev = left and revs.base or revs.right
    local key = table.concat({ rev, path, tostring(thread.line), tostring(thread.end_line), thread.side or '' }, '\0')
    if cache[key] then
      return cb(cache[key])
    end
    git_once(table.concat({ 'show', cwd, rev, path }, '\0'), { 'show', rev .. ':' .. path }, cwd, function(code, stdout)
      if code ~= 0 then
        return cb(nil, UNAVAILABLE)
      end
      local dargs = { 'diff', '--no-ext-diff', '--no-color', '-U3', revs.base, revs.right, '--', path }
      git_once(table.concat({ 'diff', cwd, revs.base, revs.right, path }, '\0'), dargs, cwd, function(dcode, dout)
        if dcode ~= 0 then
          return cb(nil, UNAVAILABLE)
        end
        local file_lines = vim.split(stdout, '\n', { plain = true })
        if file_lines[#file_lines] == '' then
          table.remove(file_lines)
        end
        local rows = M.build(thread, file_lines, M.parse_hunks(dout))
        if #rows == 0 then
          return cb(nil, UNAVAILABLE) -- e.g. thread beyond EOF
        end
        cache[key] = rows
        cb(rows)
      end)
    end)
  end, { fetch = false, check_repo = true })
end

return M
