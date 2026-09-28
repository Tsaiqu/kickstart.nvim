---@diagnostic disable: duplicate-set-field, need-check-nil, param-type-mismatch, assign-type-mismatch, redundant-parameter, cast-local-type, missing-parameter
local models = require 'azure_pr.models'
local filter = require 'azure_pr.filter'
local F = require 'azure_pr.tests.fixtures'

local ctx = { user_id = F.ME.id }
local function prs()
  return models.normalize_prs(F.prs())
end
local function ids(list)
  return vim.tbl_map(function(p)
    return p.id
  end, list)
end
local function apply(f, c)
  local out = ids(filter.apply(prs(), f, c or ctx))
  table.sort(out)
  return out
end

describe('filter.apply', function()
  it('empty / nil filters keep everything in order', function()
    eq({ 101, 102, 103, 104, 105, 106, 107, 108, 109 }, ids(filter.apply(prs(), nil, ctx)))
    eq(9, #filter.apply(prs(), {}, nil))
    eq({}, filter.apply(nil, {}, ctx))
  end)

  it('text matches title case-insensitively', function()
    eq({ 101 }, apply { text = 'RETRY policy' })
  end)
  it('text matches id', function()
    eq({ 103 }, apply { text = '103' })
    eq({ 103 }, apply { text = '!103' })
  end)
  it('text matches author name, repo name, source branch', function()
    eq({ 103, 105, 109 }, apply { text = 'anna' })
    eq({ 102, 103, 106 }, apply { text = 'web app' })
    eq({ 104 }, apply { text = 'chore/' })
  end)
  it('empty text is ignored', function()
    eq(9, #filter.apply(prs(), { text = '' }, ctx))
  end)
  it('text with pattern characters is literal', function()
    eq({}, apply { text = '.*' })
    eq({ 102 }, apply { text = 'wip:' })
  end)

  it('author substring on name or unique name', function()
    eq({ 101, 106, 107, 108 }, apply { author = 'kowal' })
    eq({ 101, 106, 107, 108 }, apply { author = 'jan.kowalski@' })
  end)
  it('repository substring', function()
    eq({ 102, 103, 106 }, apply { repository = 'WEB' })
  end)
  it('target_branch substring', function()
    eq({ 102 }, apply { target_branch = 'devel' })
    eq({ 109 }, apply { target_branch = 'release' })
  end)
  it('draft true / false', function()
    eq({ 102 }, apply { draft = true })
    eq({ 101, 103, 104, 105, 106, 107, 108, 109 }, apply { draft = false })
  end)
  it('created_by_me', function()
    eq({ 102, 104 }, apply { created_by_me = true })
    eq(9, #filter.apply(prs(), { created_by_me = false }, ctx), 'false = do not care')
    eq({}, apply({ created_by_me = true }, {}), 'unknown user matches nothing')
  end)
  it('reviewer_is_me (direct reviewers only)', function()
    eq({ 101, 103, 105, 107, 109 }, apply { reviewer_is_me = true })
  end)
  it('needs_my_vote: reviewer, vote 0, active, not draft', function()
    eq({ 101, 109 }, apply { needs_my_vote = true })
    local list = prs()
    list[1].is_draft = true
    eq({ 109 }, ids(filter.apply(list, { needs_my_vote = true }, ctx)))
  end)
  it('review_state exact', function()
    eq({ 101, 106 }, apply { review_state = 'approved_suggestions' })
    eq({ 105 }, apply { review_state = 'approved' })
  end)
  it('combines filters with AND', function()
    eq({ 101 }, apply { repository = 'api', needs_my_vote = true, author = 'jan' })
    eq({}, apply { draft = true, created_by_me = true, review_state = 'approved' })
  end)
  it('does not mutate input', function()
    local list = prs()
    filter.apply(list, { text = 'x' }, ctx)
    eq(9, #list)
  end)
end)

describe('filter.group', function()
  local function shape(groups)
    return vim.tbl_map(function(g)
      return { g.key, g.label, ids(g.items) }
    end, groups)
  end

  it('GROUP_BY list', function()
    eq({ 'none', 'repository', 'author', 'review_state', 'target_branch', 'my_vote' }, filter.GROUP_BY)
  end)

  it('none -> single group, items sorted by created_at desc', function()
    eq({ { '', 'All', { 109, 102, 103, 101, 104, 105, 106, 107, 108 } } }, shape(filter.group(prs(), 'none', ctx)))
    eq({ { '', 'All', {} } }, shape(filter.group({}, 'none', ctx)))
    eq('All', filter.group(prs(), nil, ctx)[1].label, 'nil -> none')
    eq('All', filter.group(prs(), 'bogus', ctx)[1].label, 'unknown -> none')
  end)

  it('repository sorted by label case-insensitively', function()
    eq({
      { 'api-service', 'api-service', { 109, 101, 104, 105, 107, 108 } },
      { 'Web App', 'Web App', { 102, 103, 106 } },
    }, shape(filter.group(prs(), 'repository', ctx)))
  end)

  it('author keyed by id, labelled by name', function()
    eq({
      { F.ANNA.id, 'Anna Nowak', { 109, 103, 105 } },
      { F.JAN.id, 'Jan Kowalski', { 101, 106, 107, 108 } },
      { F.ME.id, 'Kamil Sasin', { 102, 104 } },
    }, shape(filter.group(prs(), 'author', ctx)))
  end)

  it('review_state in fixed logical order', function()
    eq({
      { 'rejected', 'Rejected', { 103 } },
      { 'waiting', 'Waiting for author', { 104 } },
      { 'no_votes', 'No votes', { 109 } },
      { 'approved_suggestions', 'Approved with suggestions', { 101, 106 } },
      { 'approved', 'Approved', { 105 } },
      { 'draft', 'Draft', { 102 } },
      { 'completed', 'Completed', { 107 } },
      { 'abandoned', 'Abandoned', { 108 } },
    }, shape(filter.group(prs(), 'review_state', ctx)))
  end)

  it('target_branch', function()
    eq({
      { 'develop', 'develop', { 102 } },
      { 'main', 'main', { 103, 101, 104, 105, 106, 107, 108 } },
      { 'release/2.0', 'release/2.0', { 109 } },
    }, shape(filter.group(prs(), 'target_branch', ctx)))
  end)

  it('my_vote labelled via vote_label, Not a reviewer for nil', function()
    eq({
      { '10', 'Approved', { 105, 107 } },
      { '0', 'No vote', { 109, 101 } },
      { 'none', 'Not a reviewer', { 102, 104, 106, 108 } },
      { '-10', 'Rejected', { 103 } },
    }, shape(filter.group(prs(), 'my_vote', ctx)))
    eq({ { 'none', 'Not a reviewer', { 109, 102, 103, 101, 104, 105, 106, 107, 108 } } }, shape(filter.group(prs(), 'my_vote', {})))
  end)

  it('ties on created_at broken by id desc; missing created_at last', function()
    local list = {
      { id = 1, created_at = 100 },
      { id = 2, created_at = 100 },
      { id = 3 },
      { id = 4, created_at = 200 },
    }
    eq({ 4, 2, 1, 3 }, ids(filter.group(list, 'none', ctx)[1].items))
  end)

  it('does not reorder the input list', function()
    local list = prs()
    filter.group(list, 'none', ctx)
    eq(101, list[1].id)
  end)
end)

describe('filter.describe / is_empty', function()
  it('empty', function()
    eq('', filter.describe(nil))
    eq('', filter.describe {})
    eq('', filter.describe { text = '', created_by_me = false, needs_my_vote = false, reviewer_is_me = false })
    truthy(filter.is_empty(nil))
    truthy(filter.is_empty { text = '' })
    truthy(filter.is_empty { created_by_me = false })
  end)
  it('describes each filter', function()
    eq('text:"foo" author:jan draft:no mine', filter.describe { text = 'foo', author = 'jan', draft = false, created_by_me = true })
    eq(
      'repo:web target:main draft:yes reviewer:me needs-my-vote state:approved',
      filter.describe { repository = 'web', target_branch = 'main', draft = true, reviewer_is_me = true, needs_my_vote = true, review_state = 'approved' }
    )
    falsy(filter.is_empty { draft = false })
    falsy(filter.is_empty { text = 'x' })
  end)
end)

describe('filter exact values (review fixes)', function()
  it("a leading '=' means exact case-insensitive match", function()
    local m = filter._value_matches
    truthy(m('main', '=MAIN'))
    falsy(m('maintenance', '=main'))
    truthy(m('maintenance', 'main'), 'substring without =')
    falsy(m(nil, '=main'))
    local list = {
      { id = 1, target_branch = 'main', repository = { name = 'backend' }, author = { name = 'Jan' } },
      { id = 2, target_branch = 'maintenance', repository = { name = 'backend-tests' }, author = { name = 'Janusz' } },
    }
    local function only(f)
      return ids(filter.apply(list, f, ctx))
    end
    eq({ 1 }, only { target_branch = '=main' })
    eq({ 1 }, only { repository = '=backend' })
    eq({ 1 }, only { author = '=jan' })
    eq({ 1, 2 }, only { author = 'jan' })
    eq('target:=main', filter.describe { target_branch = '=main' })
  end)
end)
