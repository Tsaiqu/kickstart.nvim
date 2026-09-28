---@diagnostic disable: duplicate-set-field, need-check-nil, param-type-mismatch, assign-type-mismatch, redundant-parameter, cast-local-type, missing-parameter
local render = require 'azure_pr.ui.render'
local hl = require 'azure_pr.ui.highlights'

local NOW = 1700000000
local DAY = 86400
local icons = hl.icons(false) -- ascii, deterministic

local function mkpr(id, o)
  o = o or {}
  return {
    id = id,
    title = o.title or ('PR number ' .. id),
    description = o.description,
    status = o.status or 'active',
    is_draft = o.is_draft or false,
    merge_status = o.merge_status,
    created_at = o.created_at or (NOW - 3 * DAY),
    author = o.author or { id = 'u1', name = 'Jan Kowalski', unique_name = 'jan@x.pl' },
    repository = o.repository or { id = 'r1', name = 'repo-a', project_id = 'p1', project_name = 'Proj' },
    source_branch = o.source_branch or 'feature/x',
    target_branch = o.target_branch or 'main',
    reviewers = o.reviewers or {},
    review_state = o.review_state or 'no_votes',
    labels = o.labels or {},
    url = o.url,
  }
end

local function comment(id, parent, author, content, ts, extra)
  local c = { id = id, parent_id = parent, author = { id = author, name = author }, content = content, published_at = ts or NOW - DAY, type = 'text' }
  for k, v in pairs(extra or {}) do
    c[k] = v
  end
  return c
end

local function check_result(res)
  truthy(type(res.lines) == 'table')
  for i, l in ipairs(res.lines) do
    falsy(l:find '[\r\n]', 'line ' .. i .. ' contains newline: ' .. vim.inspect(l))
  end
  for _, h in ipairs(res.highlights) do
    truthy(h[1] >= 0 and h[1] < #res.lines, 'hl line in range ' .. vim.inspect(h))
    local len = #res.lines[h[1] + 1]
    truthy(h[2] >= 0 and h[2] <= len, 'hl start in range ' .. vim.inspect(h))
    truthy(h[3] == -1 or (h[3] >= h[2] and h[3] <= len), 'hl end in range ' .. vim.inspect(h))
    truthy(type(h[4]) == 'string' and h[4]:match '^AzurePR', 'hl group ' .. vim.inspect(h))
  end
end

local function find_line(res, needle, from)
  for i = from or 1, #res.lines do
    if res.lines[i]:find(needle, 1, true) then
      return i
    end
  end
end

describe('highlights', function()
  it('defines groups with default links', function()
    hl.setup()
    local g = vim.api.nvim_get_hl(0, { name = 'AzurePRApproved' })
    eq('DiagnosticOk', g.link)
    -- user override survives setup (default = true)
    vim.api.nvim_set_hl(0, 'AzurePRId', { fg = '#ff0000' })
    hl.setup()
    eq(nil, vim.api.nvim_get_hl(0, { name = 'AzurePRId' }).link)
    truthy(vim.api.nvim_get_hl(0, { name = 'AzurePRId' }).fg)
  end)

  it('icons have all keys in both modes', function()
    local keys = {
      'approved',
      'rejected',
      'waiting',
      'no_vote',
      'draft',
      'completed',
      'abandoned',
      'thread_active',
      'thread_resolved',
      'comment',
      'file',
      'collapsed',
      'expanded',
      'user',
    }
    for _, mode in ipairs { true, false } do
      local ic = hl.icons(mode)
      for _, k in ipairs(keys) do
        truthy(type(ic[k]) == 'string' and #ic[k] > 0, 'icon ' .. k)
      end
    end
    eq('v', hl.icons(false).expanded)
  end)

  it('namespace exists', function()
    truthy(type(hl.ns) == 'number')
  end)
end)

describe('render.pr_list', function()
  local groups = {
    {
      key = 'repo-a',
      label = 'repo-a',
      items = {
        mkpr(101, { title = 'Short', review_state = 'approved' }),
        mkpr(7, { title = 'A much longer title with ąęś unicode', author = { id = 'u2', name = 'Zażółć' }, created_at = NOW - 5 * 3600 }),
      },
    },
    {
      key = 'repo-b',
      label = 'repo-b',
      items = { mkpr(55, { title = 'multi\nline title', is_draft = true, review_state = 'draft', source_branch = 'fix/y', target_branch = 'develop' }) },
    },
  }

  it('renders header, hint, groups and rows', function()
    local res = render.pr_list(groups, { status = 'active', group_by = 'repository', filters_desc = 'mine', total = 40, now = NOW, icons = icons })
    check_result(res)
    contains(res.lines[1], 'Azure DevOps PRs')
    contains(res.lines[1], '[active]')
    contains(res.lines[1], 'group: repository')
    contains(res.lines[1], 'filter: mine')
    contains(res.lines[1], '(3/40)')
    contains(res.lines[2], '? help')
    eq('', res.lines[3])
    local gl = find_line(res, 'repo-a (2)')
    truthy(gl)
    eq('v repo-a (2)', res.lines[gl])
    eq('group', res.items[gl].kind)
    eq('repo-a', res.items[gl].group_key)
    local row = find_line(res, '!101')
    eq('pr', res.items[row].kind)
    eq(101, res.items[row].pr.id)
    eq('repo-a', res.items[row].group_key)
    contains(res.lines[row], 'Jan Kowalski')
    contains(res.lines[row], 'feature/x -> main')
    contains(res.lines[row], '3d ago')
    contains(res.lines[find_line(res, '!7 ')], '5h ago')
    contains(res.lines[find_line(res, '!55')], 'multi line title')
  end)

  it('aligns columns by display width', function()
    local res = render.pr_list(groups, { now = NOW, icons = icons })
    local rows = {}
    for i = 1, #res.lines do
      if res.items[i] and res.items[i].kind == 'pr' then
        rows[#rows + 1] = res.lines[i]
      end
    end
    eq(3, #rows)
    local function col_of(line, needle)
      local s = line:find(needle, 1, true)
      return vim.fn.strdisplaywidth(line:sub(1, s - 1))
    end
    -- title column
    eq(col_of(rows[1], 'Short'), col_of(rows[2], 'A much'))
    -- author column (Zażółć has multibyte chars)
    eq(col_of(rows[1], 'Jan'), col_of(rows[2], 'Zażółć'))
    -- branch column
    eq(col_of(rows[1], 'feature/x'), col_of(rows[3], 'fix/y'))
    -- age column
    eq(col_of(rows[1], '3d ago'), col_of(rows[2], '5h ago'))
  end)

  it('truncates titles to fit width', function()
    local long = { { key = 'k', label = 'k', items = { mkpr(1, { title = string.rep('x', 200) }) } } }
    local res = render.pr_list(long, { now = NOW, icons = icons, width = 100 })
    check_result(res)
    local row = find_line(res, '!1')
    contains(res.lines[row], '…')
    truthy(vim.fn.strdisplaywidth(res.lines[row]) <= 100, 'row fits width: ' .. vim.fn.strdisplaywidth(res.lines[row]))
  end)

  it('collapsed groups hide rows', function()
    local res = render.pr_list(groups, { now = NOW, icons = icons, collapsed = { ['repo-a'] = true } })
    check_result(res)
    local gl = find_line(res, 'repo-a (2)')
    eq('> repo-a (2)', res.lines[gl])
    truthy(res.items[gl].collapsed)
    falsy(find_line(res, '!101'))
    truthy(find_line(res, '!55'))
  end)

  it('highlights id, author, state icon', function()
    local res = render.pr_list(groups, { now = NOW, icons = icons })
    local row = find_line(res, '!101')
    local found = {}
    for _, h in ipairs(res.highlights) do
      if h[1] == row - 1 then
        found[h[4]] = res.lines[row]:sub(h[2] + 1, h[3])
      end
    end
    eq('!101', found.AzurePRId:gsub('%s+$', ''))
    eq('+', found.AzurePRApproved)
    contains(found.AzurePRAuthor, 'Jan Kowalski')
  end)

  it('empty list shows message', function()
    local res = render.pr_list({}, { now = NOW, icons = icons, filters_desc = 'x' })
    check_result(res)
    truthy(find_line(res, 'No pull requests match'))
    contains(res.lines[1], '(0)')
  end)
end)

describe('render.pr_detail', function()
  local pr = mkpr(123, {
    title = 'Add feature',
    description = 'Line one\r\n\r\n- bullet\nlast',
    merge_status = 'succeeded',
    url = 'https://dev.azure.com/o/p/_git/r/pullrequest/123',
    review_state = 'waiting',
    reviewers = {
      { id = 'u9', name = 'Anna', vote = 10, is_required = true },
      { id = 'me', name = 'Me Myself', vote = -5 },
      { id = 'g1', name = '[Proj]\\Team', vote = 0, is_container = true },
    },
  })
  local threads = {
    {
      id = 1,
      status = 'active',
      comments = {
        comment(10, 0, 'Anna', 'Top level\nsecond line', NOW - 2 * DAY),
        comment(11, 10, 'me', 'Reply one', NOW - DAY),
        comment(12, 11, 'Anna', 'Nested reply', NOW - 3600),
        comment(13, 10, 'Bob', 'Reply two', NOW - 60),
      },
    },
    {
      id = 2,
      status = 'fixed',
      file_path = '/src/main.lua',
      line = 42,
      comments = { comment(20, 0, 'Bob', 'Fix this', NOW - DAY) },
    },
    {
      id = 3,
      status = 'pending',
      file_path = '/lua/x.lua',
      line = 5,
      end_line = 8,
      comments = { comment(30, 0, 'Bob', 'range', NOW - DAY), comment(31, 30, 'Anna', 'gone', NOW, { is_deleted = true }) },
    },
  }
  local statuses = { { state = 'succeeded', description = 'Build ok', context = { name = 'build', genre = 'ci' } } }
  local policies = {
    { status = 'rejected', configuration = { isBlocking = true, type = { displayName = 'Minimum number of reviewers' } } },
    { status = 'approved', configuration = { isBlocking = false, type = { displayName = 'Comment requirements' } } },
  }

  local function do_render(o)
    o = vim.tbl_extend('force', { now = NOW, icons = icons, user_id = 'me', statuses = statuses, policies = policies, date_format = '%Y' }, o or {})
    local res = render.pr_detail(pr, threads, o)
    check_result(res)
    return res
  end

  it('renders title, hint and meta', function()
    local res = do_render()
    eq('!123 Add feature', res.lines[1])
    eq('pr', res.items[1].kind)
    contains(res.lines[2], '? help')
    truthy(find_line(res, 'Status:'))
    contains(res.lines[find_line(res, 'Branches:')], 'feature/x -> main')
    contains(res.lines[find_line(res, 'Merge:')], 'succeeded')
    contains(res.lines[find_line(res, 'URL:')], 'pullrequest/123')
    contains(res.lines[find_line(res, 'Author:')], 'Jan Kowalski')
    contains(res.lines[find_line(res, 'Review:')], 'Waiting for author')
    -- keys aligned
    local a = res.lines[find_line(res, 'Status:')]:find('active', 1, true)
    local r = res.lines[find_line(res, 'Repository:')]:find('repo-a', 1, true)
    eq(a, r)
  end)

  it('renders reviewers with votes', function()
    local res = do_render()
    local l = find_line(res, 'Reviewers (3)')
    truthy(l)
    local anna = find_line(res, 'Anna', l)
    contains(res.lines[anna], 'Approved')
    contains(res.lines[anna], 'required')
    eq('reviewer', res.items[anna].kind)
    local me = find_line(res, 'Me Myself')
    contains(res.lines[me], 'Waiting for author')
    contains(res.lines[me], 'you')
    contains(res.lines[find_line(res, 'Team')], 'group')
  end)

  it('renders checks and omits section when empty', function()
    local res = do_render()
    truthy(find_line(res, 'Checks (3)'))
    contains(res.lines[find_line(res, 'ci/build')], 'succeeded')
    contains(res.lines[find_line(res, 'Minimum number of reviewers')], 'rejected')
    contains(res.lines[find_line(res, 'Comment requirements')], 'optional')
    local res2 = do_render { statuses = {}, policies = {} }
    falsy(find_line(res2, 'Checks'))
  end)

  it('renders description split into lines', function()
    local res = do_render()
    local d = find_line(res, 'Description')
    eq('  Line one', res.lines[d + 1])
    eq('', res.lines[d + 2])
    eq('  - bullet', res.lines[d + 3])
    eq('  last', res.lines[d + 4])
    local p2 = vim.deepcopy(pr)
    p2.description = nil
    local res2 = render.pr_detail(p2, {}, { now = NOW, icons = icons })
    check_result(res2)
    truthy(find_line(res2, '(no description)'))
    truthy(find_line(res2, 'No comments yet'))
  end)

  it('renders threads with counts, locations and nested replies', function()
    local res = do_render()
    truthy(find_line(res, 'Threads (2/3)'))
    local t1 = find_line(res, '[active] General')
    truthy(t1)
    eq('thread', res.items[t1].kind)
    eq(1, res.items[t1].thread.id)
    local t2 = find_line(res, '[fixed]')
    contains(res.lines[t2], 'src/main.lua:42')
    falsy(res.lines[t2]:find('/src', 1, true))
    contains(res.lines[find_line(res, '[pending]')], 'lua/x.lua:5-8')

    local function indent(l)
      return #res.lines[l]:match '^( *)'
    end
    local top = find_line(res, 'Anna', t1)
    local r1 = find_line(res, '> me', t1)
    local nested = find_line(res, 'Nested reply', t1) - 1
    local r2 = find_line(res, '> Bob', t1)
    eq('comment', res.items[top].kind)
    eq(10, res.items[top].comment.id)
    eq(indent(top) + 2, indent(r1))
    eq(indent(r1) + 2, indent(nested))
    eq(indent(top) + 2, indent(r2))
    -- depth-first order: top, reply one, nested, reply two
    truthy(top < r1 and r1 < nested and nested < r2)
    -- content lines map to comment
    local second = find_line(res, 'second line', t1)
    eq(10, res.items[second].comment.id)
    eq(indent(top) + 2, indent(second))
    contains(res.lines[top], '2d ago')
    contains(res.lines[r1], '(you)')
    truthy(find_line(res, '(deleted)'))
  end)

  it('hides resolved threads when show_resolved = false', function()
    local res = do_render { show_resolved = false }
    falsy(find_line(res, '[fixed]'))
    truthy(find_line(res, '[pending]'))
    truthy(find_line(res, '1 resolved hidden'))
    truthy(find_line(res, 'Threads (2/3)'))
  end)

  it('folds threads', function()
    local res = do_render { folded = { [1] = true } }
    local t1 = find_line(res, '[active] General')
    contains(res.lines[t1], '(4 comments)')
    contains(res.lines[t1], '> ') -- collapsed icon in ascii
    truthy(res.items[t1].folded)
    falsy(find_line(res, 'Top level'))
    truthy(find_line(res, 'Fix this'))
  end)

  it('thread status highlights', function()
    local res = do_render()
    local t2 = find_line(res, '[fixed]')
    local t1 = find_line(res, '[active]')
    local groups = {}
    for _, h in ipairs(res.highlights) do
      if h[1] == t2 - 1 or h[1] == t1 - 1 then
        groups[h[4] .. (h[1] + 1)] = true
      end
    end
    truthy(groups['AzurePRThreadResolved' .. t2])
    truthy(groups['AzurePRThreadActive' .. t1])
    truthy(groups['AzurePRFile' .. t2])
  end)

  it('never emits newlines from any field', function()
    local nasty = mkpr(9, {
      title = 'a\nb',
      author = { name = 'x\ny' },
      source_branch = 's\r\n',
      url = 'u\n',
      reviewers = { { name = 'r\nr', vote = 5 } },
    })
    local th = { { id = 5, status = 'active', file_path = '/a\nb', line = 1, comments = { comment(1, 0, 'a\nb', 'x\r\ny\rz') } } }
    local res = render.pr_detail(nasty, th, { now = NOW, icons = icons })
    check_result(res)
    local res2 = render.pr_list({ { key = 'a\nb', label = 'a\nb', items = { nasty } } }, { now = NOW, icons = icons })
    check_result(res2)
  end)

  it('works with nerd icons and defaults', function()
    local res = render.pr_detail(pr, threads, {})
    check_result(res)
    local res2 = render.pr_list { { key = 'k', label = 'k', items = { pr } } }
    check_result(res2)
  end)
end)

describe('render (review fixes)', function()
  local pr = mkpr(7, { title = 'T' })

  it('latest_statuses keeps one status per context (iteration, then date, then id)', function()
    local list = {
      { id = 1, iterationId = 1, state = 'pending', context = { genre = 'ci', name = 'build' }, creationDate = '2024-01-01T10:00:00Z' },
      { id = 2, iterationId = 1, state = 'succeeded', context = { genre = 'ci', name = 'build' }, creationDate = '2024-01-01T10:05:00Z' },
      { id = 3, iterationId = 1, state = 'failed', context = { name = 'lint' } },
      { id = 4, iterationId = 2, state = 'pending', context = { name = 'lint' } },
    }
    local out = render.latest_statuses(list)
    eq(2, #out)
    eq(2, out[1].id)
    eq(4, out[2].id)
    local res = render.pr_detail(pr, {}, { now = NOW, icons = icons, statuses = list })
    check_result(res)
    truthy(find_line(res, 'Checks (2)'))
    contains(res.lines[find_line(res, 'ci/build')], 'succeeded')
    falsy(find_line(res, 'failed'))
  end)

  it('threads loading / error states instead of "No comments yet"', function()
    local res = render.pr_detail(pr, {}, { now = NOW, icons = icons, threads_loading = true })
    truthy(find_line(res, 'Loading comments'))
    falsy(find_line(res, 'No comments yet'))
    res = render.pr_detail(pr, {}, { now = NOW, icons = icons, threads_error = 'HTTP 500' })
    contains(res.lines[find_line(res, 'Failed to load threads')], 'HTTP 500')
    contains(res.lines[find_line(res, 'Failed to load threads')], 'R to retry')
    falsy(find_line(res, 'No comments yet'))
  end)

  it('hints follow the keymap config', function()
    eq(
      { { 'gr', 'refresh' } },
      vim.tbl_filter(function(h)
        return h[2] == 'refresh'
      end, render.hints('list', { refresh = { 'gr', 'R' } }))
    )
    eq(
      {},
      vim.tbl_filter(function(h)
        return h[2] == 'vote'
      end, render.hints('detail', { vote = false }))
    )
    local res = render.pr_list({}, { icons = icons, hints = render.hints('list', { refresh = 'gr' }) })
    contains(res.lines[2], 'gr refresh')
    eq('Press gr to retry, x to close.', render.retry_hint { refresh = 'gr', close = { 'x', 'q' } })
    local d = render.pr_detail(pr, {}, { now = NOW, icons = icons, keymaps = { comment = 'C' } })
    contains(d.lines[find_line(d, 'No comments yet')], 'C to add one')
  end)

  it('header marks a truncated list', function()
    local res = render.pr_list({}, { icons = icons, total = 200, truncated = true })
    contains(res.lines[1], '(0/200+)')
    contains(res.lines[1], 'max_prs reached')
  end)
end)
