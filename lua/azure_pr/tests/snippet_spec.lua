---@diagnostic disable: duplicate-set-field, need-check-nil, param-type-mismatch, missing-parameter
-- Tests for azure_pr.snippet (diff parsing, row building, git-backed get).

local DIFF = table.concat({
  'diff --git a/src/a.py b/src/a.py',
  'index 111..222 100644',
  '--- a/src/a.py',
  '+++ b/src/a.py',
  '@@ -40,2 +40,3 @@ def f():',
  ' ctx40',
  '-old41',
  '+new41',
  '+new42',
  '\\ No newline at end of file',
}, '\n') .. '\n'

local function lines(n)
  local t = {}
  for i = 1, n do
    t[i] = 'line' .. i
  end
  return t
end

local function map(t, f)
  return vim.tbl_map(f, t)
end

describe('snippet.parse_hunks', function()
  local snippet = require 'azure_pr.snippet'
  it('parses one hunk with kinds and skips no-newline marker', function()
    local h = snippet.parse_hunks(DIFF)
    eq(1, #h)
    eq(40, h[1].old_start)
    eq(40, h[1].new_start)
    eq(2, h[1].old_count)
    eq(3, h[1].new_count)
    eq(4, #h[1].lines)
    eq({ ' ', '-', '+', '+' }, map(h[1].lines, function(l) return l.kind end))
    eq('old41', h[1].lines[2].text)
  end)
  it('defaults missing counts to 1', function()
    local h = snippet.parse_hunks '@@ -5 +5 @@\n-a\n+b\n'
    eq(1, h[1].old_count)
    eq(1, h[1].new_count)
  end)
end)

describe('snippet.build', function()
  local snippet = require 'azure_pr.snippet'
  local hunks = snippet.parse_hunks(DIFF)

  it('right thread over a hunk gives hunk rows with focus on new lines', function()
    local rows = snippet.build({ side = 'right', line = 41, end_line = 42 }, lines(50), hunks)
    eq(4, #rows)
    eq({ kind = ' ', old = 40, new = 40, text = 'ctx40', focus = false }, rows[1])
    eq({ kind = '-', old = 41, new = nil, text = 'old41', focus = false }, rows[2])
    eq({ kind = '+', old = nil, new = 41, text = 'new41', focus = true }, rows[3])
    eq(true, rows[4].focus)
    eq(42, rows[4].new)
  end)

  it('range without a hunk gives context rows from file_lines', function()
    local rows = snippet.build({ side = 'right', line = 10, end_line = 10 }, lines(50), hunks)
    eq({ 8, 9, 10 }, map(rows, function(r) return r.new end))
    eq({ false, false, true }, map(rows, function(r) return r.focus end))
    eq(' ', rows[1].kind)
    eq(8, rows[1].old)
  end)

  it('left thread on a removed line focuses the - row', function()
    local rows = snippet.build({ side = 'left', line = 41, end_line = 41 }, lines(50), hunks)
    local focus = vim.tbl_filter(function(r) return r.focus end, rows)
    eq(1, #focus)
    eq('-', focus[1].kind)
    eq(41, focus[1].old)
  end)

  it('line beyond EOF gives no rows; partially beyond is clamped', function()
    eq({}, snippet.build({ side = 'right', line = 200, end_line = 200 }, lines(50), {}))
    local rows = snippet.build({ side = 'right', line = 49, end_line = 60 }, lines(50), {})
    local focus = map(vim.tbl_filter(function(r) return r.focus end, rows), function(r) return r.new end)
    eq({ 49, 50 }, focus)
  end)

  it('replaces tabs with spaces', function()
    local rows = snippet.build({ side = 'right', line = 2, end_line = 2 }, { 'a', '\tb' }, {})
    eq('    b', rows[#rows].text)
  end)

  it('respects opts.context', function()
    local rows = snippet.build({ side = 'right', line = 10, end_line = 10 }, lines(50), {}, { context = 0 })
    eq(1, #rows)
  end)
end)

describe('snippet.get', function()
  local actions, snippet, calls, show_code

  local function setup()
    reset_modules()
    actions = require 'azure_pr.actions'
    snippet = require 'azure_pr.snippet'
    calls = {}
    show_code = 0
    actions.resolve_pr_revs = function(_, _, cb)
      cb(nil, { left = 'L', right = 'R', base = 'B' })
    end
    actions._git = function(args, _, cb)
      table.insert(calls, table.concat(args, ' '))
      if args[1] == 'show' then
        return cb(show_code, show_code == 0 and 'a\nb\nc\n' or '', 'fatal')
      end
      cb(0, '', '')
    end
  end

  local thread = { file_path = '/src/a.py', line = 2, end_line = 2, side = 'right' }

  it('returns code unavailable when git show fails, and does not cache it', function()
    setup()
    show_code = 128
    local r, e
    snippet.get({}, thread, '/repo', function(rows, err) r, e = rows, err end)
    eq(nil, r)
    eq('code unavailable', e)
    show_code = 0
    snippet.get({}, thread, '/repo', function(rows, err) r, e = rows, err end)
    truthy(r)
    eq(nil, e)
  end)

  it('uses right rev for right side, base for left, strips leading slash', function()
    setup()
    snippet.get({}, thread, '/repo', function() end)
    eq('show R:src/a.py', calls[1])
    truthy(calls[2]:find('diff --no-ext-diff --no-color -U3 B R -- src/a.py', 1, true))
    setup()
    snippet.get({}, vim.tbl_extend('force', thread, { side = 'left' }), '/repo', function() end)
    eq('show B:src/a.py', calls[1])
  end)

  it('caches successful results', function()
    setup()
    local r1, r2
    snippet.get({}, thread, '/repo', function(rows) r1 = rows end)
    local n = #calls
    snippet.get({}, thread, '/repo', function(rows) r2 = rows end)
    eq(n, #calls)
    eq(r1, r2)
    snippet.clear_cache()
    snippet.get({}, thread, '/repo', function() end)
    truthy(#calls > n)
  end)

  it('maps resolve_pr_revs errors to code unavailable', function()
    setup()
    actions.resolve_pr_revs = function(_, _, cb) cb 'boom' end
    local r, e
    snippet.get({}, thread, '/repo', function(rows, err) r, e = rows, err end)
    eq(nil, r)
    eq('code unavailable', e)
    eq(0, #calls)
  end)

  it('passes --no-ext-diff and --no-color to git diff', function()
    setup()
    snippet.get({}, thread, '/repo', function() end)
    truthy(calls[2]:find('--no-ext-diff --no-color', 1, true))
  end)

  it('reports a thread beyond EOF as code unavailable', function()
    setup()
    local r, e
    snippet.get({}, vim.tbl_extend('force', thread, { line = 99, end_line = 99 }), '/repo', function(rows, err) r, e = rows, err end)
    eq(nil, r)
    eq('code unavailable', e)
  end)

  it('runs show/diff once for concurrent threads of one file', function()
    setup()
    local held = {}
    local orig = actions._git
    actions._git = function(args, o, cb)
      table.insert(held, function() orig(args, o, cb) end)
    end
    local done = 0
    for l = 1, 3 do
      snippet.get({}, vim.tbl_extend('force', thread, { line = l, end_line = l }), '/repo', function() done = done + 1 end)
    end
    while #held > 0 do table.remove(held, 1)() end
    eq(3, done)
    eq(2, #calls)
  end)

  it('uses the real resolve: wrong-repo cwd -> no fetch, code unavailable for all', function()
    setup()
    package.loaded['azure_pr.actions'] = nil
    actions = require 'azure_pr.actions'
    local git = {}
    actions._git = function(args, _, cb)
      table.insert(git, table.concat(args, ' '))
      if args[1] == 'remote' then
        return cb(0, 'https://dev.azure.com/o/p/_git/other\n', '')
      end
      cb(0, '', '')
    end
    local errs = {}
    local pr = { id = 7, source_branch = 'f', target_branch = 'main', source_commit = 's', target_commit = 't', repository = { name = 'mine' } }
    for l = 1, 4 do
      snippet.get(pr, vim.tbl_extend('force', thread, { line = l }), '/repo', function(_, e) table.insert(errs, e) end)
    end
    eq({ 'code unavailable', 'code unavailable', 'code unavailable', 'code unavailable' }, errs)
    eq({ 'remote get-url origin' }, git)
  end)
end)
