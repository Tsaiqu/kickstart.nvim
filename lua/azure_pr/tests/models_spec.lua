---@diagnostic disable: duplicate-set-field, need-check-nil, param-type-mismatch, assign-type-mismatch, redundant-parameter, cast-local-type, missing-parameter
local models = require 'azure_pr.models'
local F = require 'azure_pr.tests.fixtures'

local function by_id(list)
  local out = {}
  for _, x in ipairs(list) do
    out[x.id] = x
  end
  return out
end

describe('models.normalize_pr', function()
  it('maps all basic fields', function()
    local pr = models.normalize_pr(F.prs()[1])
    eq(101, pr.id)
    eq('Add retry policy to HTTP client', pr.title)
    eq('active', pr.status)
    eq(false, pr.is_draft)
    eq('succeeded', pr.merge_status)
    eq(1710058530, pr.created_at)
    eq(nil, pr.closed_at)
    eq({ id = F.JAN.id, name = 'Jan Kowalski', unique_name = 'jan.kowalski@example.com' }, pr.author)
    eq({ id = F.REPO_API.id, name = 'api-service', project_id = F.REPO_API.project.id, project_name = 'MyProject' }, pr.repository)
    eq('feature/retry', pr.source_branch)
    eq('main', pr.target_branch)
    eq('abc123', pr.source_commit)
    eq(nil, pr.target_commit)
    eq({ 'backend' }, pr.labels, 'inactive labels dropped')
    truthy(pr.raw.supportsIterations)
    contains(pr.description, 'exponential')
  end)

  it('maps reviewers', function()
    local pr = models.normalize_pr(F.prs()[4])
    eq(2, #pr.reviewers)
    eq(
      { id = F.JAN.id, name = 'Jan Kowalski', unique_name = F.JAN.uniqueName, vote = -5, is_required = false, is_container = false, has_declined = false },
      pr.reviewers[1]
    )
    eq(true, pr.reviewers[2].is_container)
    eq(true, pr.reviewers[2].is_required)
  end)

  it('parses closed date and tolerates missing / vim.NIL fields', function()
    local pr = models.normalize_pr(F.prs()[7])
    eq(1709730000, pr.closed_at)
    local sparse = models.normalize_pr { pullRequestId = 1, description = vim.NIL, reviewers = vim.NIL, createdBy = vim.NIL }
    eq('', sparse.description)
    eq({}, sparse.reviewers)
    eq({}, sparse.labels)
    eq('Unknown', sparse.author.name)
    eq('active', sparse.status)
    eq('no_votes', sparse.review_state)
  end)

  it('computes review_state for the fixture list', function()
    local prs = by_id(models.normalize_prs(F.prs()))
    eq('approved_suggestions', prs[101].review_state, '10 but required reviewer pending')
    eq('draft', prs[102].review_state)
    eq('rejected', prs[103].review_state)
    eq('waiting', prs[104].review_state)
    eq('approved', prs[105].review_state)
    eq('approved_suggestions', prs[106].review_state)
    eq('completed', prs[107].review_state)
    eq('abandoned', prs[108].review_state)
    eq('no_votes', prs[109].review_state)
  end)
end)

describe('models.compute_review_state', function()
  local s = models.compute_review_state
  local function r(vote, extra)
    return vim.tbl_extend('force', { vote = vote, is_required = false, is_container = false, has_declined = false }, extra or {})
  end
  it('status wins over everything', function()
    eq('completed', s('completed', true, { r(-10) }))
    eq('abandoned', s('abandoned', false, { r(10) }))
  end)
  it('draft wins over votes', function()
    eq('draft', s('active', true, { r(-10) }))
  end)
  it('rejected beats waiting beats approvals', function()
    eq('rejected', s('active', false, { r(10), r(-5), r(-10) }))
    eq('waiting', s('active', false, { r(10), r(-5) }))
  end)
  it('no votes', function()
    eq('no_votes', s('active', false, {}))
    eq('no_votes', s('active', false, { r(0), r(0, { is_required = true }) }))
  end)
  it('approved requires a 10 and all required non-container reviewers >= 5', function()
    eq('approved', s('active', false, { r(10) }))
    eq('approved', s('active', false, { r(10), r(5, { is_required = true }) }))
    eq('approved', s('active', false, { r(10), r(0) }), 'optional pending reviewer does not block')
    eq('approved', s('active', false, { r(10), r(0, { is_required = true, is_container = true }) }), 'required group ignored')
    eq('approved', s('active', false, { r(10), r(0, { is_required = true, has_declined = true }) }), 'declined ignored')
    eq('approved_suggestions', s('active', false, { r(10), r(0, { is_required = true }) }))
  end)
  it('approved with suggestions', function()
    eq('approved_suggestions', s('active', false, { r(5) }))
    eq('approved_suggestions', s('active', false, { r(5), r(0) }))
  end)
end)

describe('models.vote_label', function()
  it('labels all votes', function()
    eq('Approved', models.vote_label(10))
    eq('Approved with suggestions', models.vote_label(5))
    eq('No vote', models.vote_label(0))
    eq('Waiting for author', models.vote_label(-5))
    eq('Rejected', models.vote_label(-10))
    eq('string', type(models.vote_label(nil)))
  end)
end)

describe('models.my_vote', function()
  it('returns vote for direct reviewer, nil otherwise', function()
    local prs = by_id(models.normalize_prs(F.prs()))
    eq(0, models.my_vote(prs[101], F.ME.id))
    eq(-10, models.my_vote(prs[103], F.ME.id))
    eq(10, models.my_vote(prs[105], F.ME.id:upper()), 'case-insensitive id')
    eq(nil, models.my_vote(prs[106], F.ME.id))
    eq(nil, models.my_vote(prs[101], nil))
  end)
  it('is_author', function()
    local prs = by_id(models.normalize_prs(F.prs()))
    eq(true, models.is_author(prs[102], F.ME.id))
    eq(false, models.is_author(prs[101], F.ME.id))
    eq(false, models.is_author(prs[102], nil))
  end)
end)

describe('models.normalize_thread', function()
  it('maps a file-anchored thread with replies', function()
    local t = models.normalize_thread(F.threads()[1])
    eq(11, t.id)
    eq('active', t.status)
    eq(false, t.is_deleted)
    eq(false, t.is_system)
    eq('/src/http/client.lua', t.file_path)
    eq(42, t.line)
    eq(45, t.end_line)
    eq(2, #t.comments)
    eq(1, t.comments[1].id, 'comments sorted by id')
    eq(0, t.comments[1].parent_id)
    eq(1, t.comments[2].parent_id)
    eq('Jan Kowalski', t.comments[1].author.name)
    eq(F.JAN.id, t.comments[1].author.id)
    eq('Please add a test\nfor the timeout path', t.comments[1].content)
    eq('text', t.comments[1].type)
    eq(false, t.comments[1].is_deleted)
    eq(1710064800, t.comments[1].published_at)
    eq(1710064800, t.published_at)
    eq(1710068400, t.updated_at)
  end)

  it('general thread (threadContext vim.NIL) with numeric status', function()
    local t = models.normalize_thread(F.threads()[2])
    eq('fixed', t.status)
    eq(nil, t.file_path)
    eq(nil, t.line)
  end)

  it('maps every numeric and string status', function()
    local expected = { [0] = 'unknown', 'active', 'fixed', 'wontFix', 'closed', 'byDesign', 'pending' }
    for n, name in pairs(expected) do
      eq(name, models.normalize_thread({ status = n }).status, 'numeric ' .. n)
      eq(name, models.normalize_thread({ status = name }).status, 'string ' .. name)
    end
    eq('wontFix', models.thread_status 'wontfix')
    eq('byDesign', models.thread_status 'BYDESIGN')
    eq('fixed', models.thread_status '2')
    eq('unknown', models.thread_status(nil))
    eq('unknown', models.thread_status(vim.NIL))
    eq('unknown', models.thread_status(99))
  end)

  it('is_thread_open', function()
    truthy(models.is_thread_open 'active')
    truthy(models.is_thread_open 'pending')
    falsy(models.is_thread_open 'fixed')
    falsy(models.is_thread_open 'closed')
  end)

  it('detects system threads', function()
    eq(true, models.normalize_thread(F.threads()[3]).is_system, 'CodeReviewThreadType + system comment')
    eq(true, models.normalize_thread({ comments = { F.comment(1, F.JAN, 'x', { commentType = 'system' }) } }).is_system, 'all system comments')
    eq(true, models.normalize_thread({ comments = { F.comment(1, F.JAN, 'x', { commentType = 3 }) } }).is_system, 'numeric system type')
    eq(true, models.normalize_thread({ properties = { CodeReviewThreadType = { ['$value'] = 'RefUpdate' } }, comments = {} }).is_system)
    eq(false, models.normalize_thread({ comments = {} }).is_system, 'empty thread is not system')
    eq(
      false,
      models.normalize_thread({ comments = { F.comment(1, F.JAN, 'x', { commentType = 'system' }), F.comment(2, F.JAN, 'y') } }).is_system,
      'mixed comments'
    )
  end)

  it('falls back to left file side and numeric comment type', function()
    local t = models.normalize_thread(F.threads()[5])
    eq('/README.md', t.file_path)
    eq(3, t.line)
    eq(3, t.end_line)
    eq('left', t.side)
    eq('wontFix', t.status)
    eq('text', t.comments[1].type)
  end)

  it('end_line defaults to line', function()
    local t = models.normalize_thread { threadContext = { filePath = '/a.lua', rightFileStart = { line = 7, offset = 1 } } }
    eq(7, t.line)
    eq(7, t.end_line)
    eq('right', t.side)
  end)

  it('keeps deleted comment flag', function()
    local t = models.normalize_thread(F.threads()[4])
    eq(true, t.is_deleted)
    eq(true, t.comments[1].is_deleted)
  end)
end)

describe('models.normalize_threads', function()
  it('drops deleted and system threads, sorts by published_at', function()
    local ts = models.normalize_threads(F.threads())
    eq(
      { 12, 11, 15 },
      vim.tbl_map(function(t)
        return t.id
      end, ts)
    )
  end)
  it('include_system keeps system threads', function()
    local ts = models.normalize_threads(F.threads(), { include_system = true })
    eq(
      { 13, 12, 11, 15 },
      vim.tbl_map(function(t)
        return t.id
      end, ts)
    )
  end)
  it('handles nil / empty input', function()
    eq({}, models.normalize_threads(nil))
    eq({}, models.normalize_threads {})
  end)
  it('ties broken by id', function()
    local ts = models.normalize_threads { { id = 3, publishedDate = '2024-01-01T00:00:00Z' }, { id = 1, publishedDate = '2024-01-01T00:00:00Z' } }
    eq(1, ts[1].id)
    eq(3, ts[2].id)
  end)
end)

describe('models.thread_stats', function()
  it('counts comments and resolved / resolvable threads', function()
    local threads = models.normalize_threads(F.threads())
    eq({ comments = 4, threads = 3, resolved = 2 }, models.thread_stats(threads))
  end)

  it('skips deleted / system comments and status-less threads', function()
    local threads = {
      { status = 'active', comments = { { type = 'text' }, { type = 'text', is_deleted = true }, { type = 'system' } } },
      { status = 'unknown', comments = { { type = 'text' } } },
      { status = 'closed', comments = {} },
    }
    eq({ comments = 2, threads = 2, resolved = 1 }, models.thread_stats(threads))
    eq({ comments = 0, threads = 0, resolved = 0 }, models.thread_stats {})
  end)
end)

describe('models.pr_checks', function()
  local BUILD = { id = '0609B952-1397-4640-95EC-E00A01B2C241' }
  local function policy(kind_type, status, o)
    return vim.tbl_deep_extend('force', { status = status, configuration = { isBlocking = true, isEnabled = true, type = kind_type } }, o or {})
  end

  it('classifies policies by type id or name', function()
    eq('build', models.policy_kind { configuration = { type = BUILD } })
    eq('comments', models.policy_kind { configuration = { type = { displayName = 'Comment requirements' } } })
    eq(nil, models.policy_kind { configuration = { type = { displayName = 'Something else' } } })
  end)

  it('splits required / optional, drops not applicable and disabled ones', function()
    local ck = models.pr_checks({ merge_status = 'succeeded', reviewers = {} }, {
      policy(BUILD, 'approved', { configuration = { settings = { displayName = 'LINT', buildDefinitionId = 1 } } }),
      policy(BUILD, 'rejected', { context = { isExpired = true }, configuration = { isBlocking = false, settings = { buildDefinitionId = 2 } } }),
      policy(BUILD, 'notApplicable', { configuration = { settings = { buildDefinitionId = 3 } } }),
      policy({ displayName = 'Work item linking' }, 'approved', { configuration = { isEnabled = false } }),
      policy({ displayName = 'Status' }, 'running', { configuration = { settings = { statusGenre = 'ci', statusName = 'sonar' } } }),
    }, {
      { state = 'succeeded', context = { genre = 'ci', name = 'sonar' } }, -- covered by the status policy
      { state = 'failed', context = { name = 'other' }, description = 'Other failed' },
    }, { definition_names = { [2] = 'TRIVY' } })
    eq({ 'LINT', 'ci/sonar' }, vim.tbl_map(function(c)
      return c.name
    end, ck.required))
    eq('LINT succeeded', ck.required[1].label)
    eq({ 'TRIVY', 'other' }, vim.tbl_map(function(c)
      return c.name
    end, ck.optional))
    eq('expired', ck.optional[1].state)
    eq('Build expired', ck.optional[1].label)
    eq('Other failed', ck.optional[2].label)
    eq(1, ck.passed)
    eq(4, ck.total)
    eq({ kind = 'merge', state = 'approved', label = 'No merge conflicts' }, ck.merge)
  end)

  it('summarises reviewer requirements', function()
    local MIN = { displayName = 'Minimum number of reviewers' }
    local function pr_with(votes, o)
      local reviewers = {}
      for i, v in ipairs(votes) do
        reviewers[i] = { name = 'R' .. i, vote = v, is_required = i == 1 }
      end
      return vim.tbl_extend('force', { reviewers = reviewers, merge_status = 'conflicts' }, o or {})
    end
    local min2 = policy(MIN, 'rejected', { configuration = { settings = { minimumApproverCount = 2 } } })
    local r = models.pr_checks(pr_with { 0, 10 }, { min2 }).reviewers
    eq('running', r.state)
    eq('Waiting for reviewers to approve', r.label)
    eq({ '1 of 2 approvals', 'required: R1' }, r.details)
    r = models.pr_checks(pr_with { 10, -10 }, { min2 }).reviewers
    eq('rejected', r.state)
    r = models.pr_checks(pr_with { 10, 5 }, { policy(MIN, 'approved') }).reviewers
    eq('approved', r.state)
    eq('Required reviewers approved', r.label)
    -- no reviewer policies: fall back to the review state
    r = models.pr_checks(pr_with({ 10 }, { review_state = 'approved' }), {}).reviewers
    eq('approved', r.state)
    eq('Merge conflicts', models.pr_checks(pr_with {}, {}).merge.label)
  end)
end)
