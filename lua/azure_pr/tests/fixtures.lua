-- Shared realistic raw Azure DevOps fixtures (shapes as returned by REST api-version 7.1).
-- Functions return fresh deep copies so specs may mutate them freely.
local F = {}

F.ME = { id = 'aaaa1111-0000-0000-0000-000000000001', displayName = 'Kamil Sasin', uniqueName = 'kamil@example.com' }
F.JAN = { id = 'bbbb2222-0000-0000-0000-000000000002', displayName = 'Jan Kowalski', uniqueName = 'jan.kowalski@example.com' }
F.ANNA = { id = 'cccc3333-0000-0000-0000-000000000003', displayName = 'Anna Nowak', uniqueName = 'anna.nowak@example.com' }
F.TEAM =
  { id = 'dddd4444-0000-0000-0000-000000000004', displayName = '[Proj]\\Backend Team', uniqueName = 'vstfs:///Classification/TeamProject/x\\Backend Team' }

F.REPO_API = {
  id = 'r0000001-0000-0000-0000-000000000001',
  name = 'api-service',
  url = 'https://dev.azure.com/myorg/p1/_apis/git/repositories/r0000001-0000-0000-0000-000000000001',
  project = { id = 'p0000001-0000-0000-0000-000000000001', name = 'MyProject', state = 'wellFormed', visibility = 'private' },
}
F.REPO_WEB = {
  id = 'r0000002-0000-0000-0000-000000000002',
  name = 'Web App',
  url = 'https://dev.azure.com/myorg/p1/_apis/git/repositories/r0000002-0000-0000-0000-000000000002',
  project = { id = 'p0000001-0000-0000-0000-000000000001', name = 'MyProject', state = 'wellFormed', visibility = 'private' },
}

local function reviewer(who, vote, extra)
  local r = vim.tbl_extend('force', vim.deepcopy(who), {
    vote = vote,
    hasDeclined = false,
    isFlagged = false,
    reviewerUrl = 'https://dev.azure.com/myorg/_apis/git/repositories/x/pullRequests/1/reviewers/' .. who.id,
    imageUrl = 'https://dev.azure.com/myorg/_api/_common/identityImage?id=' .. who.id,
  })
  return vim.tbl_extend('force', r, extra or {})
end
F.reviewer = reviewer

--- Build a raw PR, overriding any fields.
function F.pr(overrides)
  local base = {
    repository = vim.deepcopy(F.REPO_API),
    pullRequestId = 101,
    codeReviewId = 101,
    status = 'active',
    createdBy = vim.tbl_extend('force', vim.deepcopy(F.JAN), { imageUrl = 'https://x/img' }),
    creationDate = '2024-03-10T08:15:30.1234567Z',
    title = 'Add retry policy to HTTP client',
    description = 'Adds exponential backoff.\r\n\r\n- retries 3x\r\n- configurable',
    sourceRefName = 'refs/heads/feature/retry',
    targetRefName = 'refs/heads/main',
    mergeStatus = 'succeeded',
    isDraft = false,
    mergeId = 'm1',
    lastMergeSourceCommit = { commitId = 'abc123' },
    reviewers = {},
    labels = {},
    url = 'https://dev.azure.com/myorg/p1/_apis/git/repositories/r1/pullRequests/101',
    supportsIterations = true,
  }
  return vim.tbl_extend('force', base, vim.deepcopy(overrides or {}))
end

--- A realistic list of raw PRs covering all review states.
function F.prs()
  return {
    F.pr {
      pullRequestId = 101,
      title = 'Add retry policy to HTTP client',
      creationDate = '2024-03-10T08:15:30.1234567Z',
      reviewers = { reviewer(F.ME, 0, { isRequired = true }), reviewer(F.ANNA, 10) },
      labels = { { id = 'l1', name = 'backend', active = true }, { id = 'l2', name = 'old', active = false } },
    },
    F.pr {
      pullRequestId = 102,
      title = 'WIP: new dashboard',
      isDraft = true,
      repository = vim.deepcopy(F.REPO_WEB),
      createdBy = vim.deepcopy(F.ME),
      sourceRefName = 'refs/heads/feature/dashboard',
      targetRefName = 'refs/heads/develop',
      creationDate = '2024-03-12T10:00:00Z',
      reviewers = { reviewer(F.JAN, 0) },
    },
    F.pr {
      pullRequestId = 103,
      title = 'Fix login redirect',
      repository = vim.deepcopy(F.REPO_WEB),
      createdBy = vim.deepcopy(F.ANNA),
      sourceRefName = 'refs/heads/bugfix/login',
      creationDate = '2024-03-11T09:00:00Z',
      reviewers = { reviewer(F.ME, -10), reviewer(F.JAN, 10) },
    },
    F.pr {
      pullRequestId = 104,
      title = 'Bump dependencies',
      createdBy = vim.deepcopy(F.ME),
      sourceRefName = 'refs/heads/chore/deps',
      creationDate = '2024-03-09T12:00:00Z',
      reviewers = { reviewer(F.JAN, -5), reviewer(F.TEAM, 0, { isContainer = true, isRequired = true }) },
    },
    F.pr {
      pullRequestId = 105,
      title = 'Refactor models',
      createdBy = vim.deepcopy(F.ANNA),
      sourceRefName = 'refs/heads/refactor/models',
      creationDate = '2024-03-08T12:00:00Z',
      reviewers = { reviewer(F.ME, 10, { isRequired = true }), reviewer(F.JAN, 5) },
    },
    F.pr {
      pullRequestId = 106,
      title = 'Docs update',
      repository = vim.deepcopy(F.REPO_WEB),
      createdBy = vim.deepcopy(F.JAN),
      sourceRefName = 'refs/heads/docs/readme',
      creationDate = '2024-03-07T12:00:00Z',
      reviewers = { reviewer(F.ANNA, 5) },
    },
    F.pr {
      pullRequestId = 107,
      title = 'Release 1.2',
      status = 'completed',
      closedDate = '2024-03-06T13:00:00Z',
      creationDate = '2024-03-05T12:00:00Z',
      sourceRefName = 'refs/heads/release/1.2',
      reviewers = { reviewer(F.ME, 10) },
    },
    F.pr {
      pullRequestId = 108,
      title = 'Abandoned experiment',
      status = 'abandoned',
      closedDate = '2024-03-04T13:00:00Z',
      creationDate = '2024-03-03T12:00:00Z',
      sourceRefName = 'refs/heads/exp/thing',
      reviewers = {},
    },
    F.pr {
      pullRequestId = 109,
      title = 'Add metrics endpoint',
      createdBy = vim.deepcopy(F.ANNA),
      sourceRefName = 'refs/heads/feature/metrics',
      targetRefName = 'refs/heads/release/2.0',
      creationDate = '2024-03-13T12:00:00Z',
      reviewers = { reviewer(F.ME, 0) },
    },
  }
end

local function comment(id, who, content, extra)
  return vim.tbl_extend('force', {
    id = id,
    parentCommentId = 0,
    author = vim.deepcopy(who),
    content = content,
    publishedDate = '2024-03-10T09:00:00Z',
    lastUpdatedDate = '2024-03-10T09:00:00Z',
    lastContentUpdatedDate = '2024-03-10T09:00:00Z',
    commentType = 'text',
    usersLiked = {},
    _links = {},
  }, extra or {})
end
F.comment = comment

--- Realistic thread list: general, file-anchored w/ reply, numeric status, system, deleted.
function F.threads()
  return {
    {
      id = 11,
      publishedDate = '2024-03-10T10:00:00.5Z',
      lastUpdatedDate = '2024-03-10T11:00:00Z',
      comments = {
        comment(2, F.ME, 'Agreed, will fix', { parentCommentId = 1, publishedDate = '2024-03-10T11:00:00Z' }),
        comment(1, F.JAN, 'Please add a test\nfor the timeout path', { publishedDate = '2024-03-10T10:00:00Z' }),
      },
      status = 'active',
      threadContext = {
        filePath = '/src/http/client.lua',
        rightFileStart = { line = 42, offset = 1 },
        rightFileEnd = { line = 45, offset = 10 },
      },
      properties = {},
      identities = vim.NIL,
      isDeleted = false,
      pullRequestThreadContext = { iterationContext = { firstComparingIteration = 1, secondComparingIteration = 2 } },
    },
    {
      id = 12,
      publishedDate = '2024-03-10T08:00:00Z',
      lastUpdatedDate = '2024-03-10T08:00:00Z',
      comments = { comment(1, F.ANNA, 'Looks good overall', { publishedDate = '2024-03-10T08:00:00Z' }) },
      status = 2, -- numeric: fixed
      threadContext = vim.NIL,
      properties = {},
      isDeleted = false,
    },
    {
      id = 13,
      publishedDate = '2024-03-10T07:00:00Z',
      lastUpdatedDate = '2024-03-10T07:00:00Z',
      comments = {
        comment(1, { id = '00000002-0000-8888-8000-000000000000', displayName = 'Microsoft.VisualStudio.Services.TFS' }, 'Kamil Sasin voted 10', {
          commentType = 'system',
        }),
      },
      properties = {
        CodeReviewThreadType = { ['$type'] = 'System.String', ['$value'] = 'VoteUpdate' },
        CodeReviewVoteResult = { ['$type'] = 'System.String', ['$value'] = '10' },
      },
      isDeleted = false,
    },
    {
      id = 14,
      publishedDate = '2024-03-10T06:00:00Z',
      lastUpdatedDate = '2024-03-10T06:00:00Z',
      comments = { comment(1, F.JAN, 'oops', { isDeleted = true }) },
      status = 'active',
      isDeleted = true,
    },
    {
      id = 15,
      publishedDate = '2024-03-10T12:00:00Z',
      lastUpdatedDate = '2024-03-10T12:00:00Z',
      comments = { comment(1, F.JAN, 'Old file comment', { commentType = 1 }) },
      status = 'wontFix',
      threadContext = {
        filePath = '/README.md',
        leftFileStart = { line = 3, offset = 1 },
        leftFileEnd = { line = 3, offset = 5 },
      },
      isDeleted = false,
    },
  }
end

return F
