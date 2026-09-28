---@diagnostic disable: duplicate-set-field, need-check-nil, param-type-mismatch, assign-type-mismatch, redundant-parameter, cast-local-type, missing-parameter
local TARGET = { organization = 'org', project = 'My Proj', base_url = 'https://dev.azure.com' }

local function setup(opts)
  opts = opts or {}
  reset_modules()
  local cfg = vim.tbl_extend('force', { api_version = '7.1', default_status = 'active', max_prs = 200 }, opts.config or {})
  package.loaded['azure_pr.config'] = {
    get = function()
      return cfg
    end,
    get_pat = function()
      return 'pat'
    end,
    resolve_target = function(cb)
      if opts.target_err then
        return cb(opts.target_err)
      end
      cb(nil, vim.tbl_extend('force', TARGET, opts.target or {}))
    end,
  }
  local http = require 'azure_pr.http'
  local calls = {}
  local responder = opts.responder or function()
    return nil, {}
  end
  http.request = function(o, cb)
    table.insert(calls, o)
    local err, data = responder(o, #calls)
    vim.schedule(function()
      cb(err, data, err and 500 or 200)
    end)
  end
  return require 'azure_pr.api', calls
end

local function await(fn)
  local res = {}
  fn(function(err, result)
    res.done, res.err, res.result = true, err, result
  end)
  truthy(
    wait_for(function()
      return res.done
    end, 2000),
    'callback not invoked'
  )
  return res
end

local P = 'https://dev.azure.com/org/My%20Proj/_apis'

local function n_prs(n, start)
  local list = {}
  for i = 1, n do
    list[i] = { pullRequestId = (start or 0) + i }
  end
  return list
end

describe('api', function()
  it('lists PRs at project level with searchCriteria and paging', function()
    local api, calls = setup {
      responder = function(_, n)
        if n == 1 then
          return nil, { value = n_prs(100) }
        end
        return nil, { value = n_prs(30, 100) }
      end,
    }
    local res = await(function(cb)
      api.list_pull_requests({ status = 'all', creator_id = 'c1', reviewer_id = 'r1', source_ref = 'feat/x' }, cb)
    end)
    eq(nil, res.err)
    eq(130, #res.result)
    eq(2, #calls)
    eq('GET', calls[1].method)
    eq(P .. '/git/pullrequests', calls[1].url)
    eq({
      ['searchCriteria.status'] = 'all',
      ['searchCriteria.creatorId'] = 'c1',
      ['searchCriteria.reviewerId'] = 'r1',
      ['searchCriteria.sourceRefName'] = 'refs/heads/feat/x',
      ['$top'] = 100,
      ['$skip'] = 0,
    }, calls[1].query)
    eq(100, calls[2].query['$skip'])
  end)

  it('default status comes from config and max_prs caps results', function()
    local api, calls = setup {
      config = { default_status = 'completed', max_prs = 150 },
      responder = function(_, n)
        return nil, { value = n_prs(100, (n - 1) * 100) }
      end,
    }
    local res = await(function(cb)
      api.list_pull_requests({}, cb)
    end)
    eq(150, #res.result)
    eq(2, #calls)
    eq('completed', calls[1].query['searchCriteria.status'])
    eq(50, calls[2].query['$top'])
  end)

  it('queries configured repositories individually and concatenates', function()
    local api, calls = setup {
      config = { repositories = { 'repo a', 'repo-b' } },
      responder = function(o)
        if o.url:find 'repo%%20a' then
          return nil, { value = { { pullRequestId = 1 } } }
        end
        return nil, { value = { { pullRequestId = 2 }, { pullRequestId = 3 } } }
      end,
    }
    local res = await(function(cb)
      api.list_pull_requests({ status = 'active' }, cb)
    end)
    eq(nil, res.err)
    eq(
      { 1, 2, 3 },
      vim.tbl_map(function(p)
        return p.pullRequestId
      end, res.result)
    )
    eq(P .. '/git/repositories/repo%20a/pullrequests', calls[1].url)
    eq(P .. '/git/repositories/repo-b/pullrequests', calls[2].url)
  end)

  it('repository_id uses searchCriteria.repositoryId at project level', function()
    local api, calls = setup()
    await(function(cb)
      api.list_pull_requests({ repository_id = 'guid-1' }, cb)
    end)
    eq(P .. '/git/pullrequests', calls[1].url)
    eq('guid-1', calls[1].query['searchCriteria.repositoryId'])
  end)

  it('propagates errors and target errors', function()
    local api = setup {
      responder = function()
        return 'HTTP 500: boom'
      end,
    }
    local res = await(function(cb)
      api.list_pull_requests({}, cb)
    end)
    contains(res.err, 'boom')
    local api2 = setup { target_err = 'no remote' }
    res = await(function(cb)
      api2.list_threads('r', 1, cb)
    end)
    eq('no remote', res.err)
  end)

  it('get_pull_request / by id', function()
    local api, calls = setup {
      responder = function()
        return nil, { pullRequestId = 7 }
      end,
    }
    local res = await(function(cb)
      api.get_pull_request('repo-id', 7, cb)
    end)
    eq({ pullRequestId = 7 }, res.result)
    eq(P .. '/git/repositories/repo-id/pullRequests/7', calls[1].url)
    await(function(cb)
      api.get_pull_request_by_id(7, cb)
    end)
    eq(P .. '/git/pullrequests/7', calls[2].url)
  end)

  it('list_threads returns value', function()
    local api, calls = setup {
      responder = function()
        return nil, { value = { { id = 1 } }, count = 1 }
      end,
    }
    local res = await(function(cb)
      api.list_threads('r', 5, cb)
    end)
    eq({ { id = 1 } }, res.result)
    eq(P .. '/git/repositories/r/pullRequests/5/threads', calls[1].url)
  end)

  it('create_thread general', function()
    local api, calls = setup()
    await(function(cb)
      api.create_thread('r', 5, { content = 'Hello' }, cb)
    end)
    eq('POST', calls[1].method)
    eq(P .. '/git/repositories/r/pullRequests/5/threads', calls[1].url)
    eq({ comments = { { parentCommentId = 0, content = 'Hello', commentType = 1 } }, status = 'active' }, calls[1].body)
  end)

  it('create_thread file-anchored', function()
    local api, calls = setup()
    await(function(cb)
      api.create_thread('r', 5, { content = 'x', file_path = 'src\\a b.lua', line = 3, end_line = 6, status = 'pending' }, cb)
    end)
    eq({
      filePath = '/src/a b.lua',
      rightFileStart = { line = 3, offset = 1 },
      rightFileEnd = { line = 6, offset = 1 },
    }, calls[1].body.threadContext)
    eq('pending', calls[1].body.status)
    eq('/a.lua', api._thread_body({ content = 'x', file_path = '/a.lua', line = 1 }).threadContext.filePath)
    eq(1, api._thread_body({ content = 'x', file_path = './a.lua', line = 1 }).threadContext.rightFileEnd.line)
  end)

  it('reply', function()
    local api, calls = setup()
    await(function(cb)
      api.reply('r', 5, 9, 'ok', nil, cb)
    end)
    eq('POST', calls[1].method)
    eq(P .. '/git/repositories/r/pullRequests/5/threads/9/comments', calls[1].url)
    eq({ content = 'ok', parentCommentId = 1, commentType = 1 }, calls[1].body)
    await(function(cb)
      api.reply('r', 5, 9, 'ok', 3, cb)
    end)
    eq(3, calls[2].body.parentCommentId)
  end)

  it('update_thread_status / update_comment / delete_comment', function()
    local api, calls = setup()
    await(function(cb)
      api.update_thread_status('r', 5, 9, 'fixed', cb)
    end)
    eq('PATCH', calls[1].method)
    eq(P .. '/git/repositories/r/pullRequests/5/threads/9', calls[1].url)
    eq({ status = 'fixed' }, calls[1].body)
    await(function(cb)
      api.update_comment('r', 5, 9, 2, 'new', cb)
    end)
    eq('PATCH', calls[2].method)
    eq(P .. '/git/repositories/r/pullRequests/5/threads/9/comments/2', calls[2].url)
    eq({ content = 'new' }, calls[2].body)
    await(function(cb)
      api.delete_comment('r', 5, 9, 2, cb)
    end)
    eq('DELETE', calls[3].method)
    eq(P .. '/git/repositories/r/pullRequests/5/threads/9/comments/2', calls[3].url)
    eq(nil, calls[3].body)
  end)

  it('vote', function()
    local api, calls = setup()
    await(function(cb)
      api.vote('r', 5, 'user-guid', -5, cb)
    end)
    eq('PUT', calls[1].method)
    eq(P .. '/git/repositories/r/pullRequests/5/reviewers/user-guid', calls[1].url)
    eq({ vote = -5 }, calls[1].body)
  end)

  it('vote keeps isRequired (PUT resets omitted reviewer fields)', function()
    local api, calls = setup()
    await(function(cb)
      api.vote('r', 5, 'user-guid', 10, { is_required = true }, cb)
    end)
    await(function(cb)
      api.vote('r', 5, 'user-guid', 0, { is_required = false }, cb)
    end)
    eq({ vote = 10, isRequired = true }, calls[1].body)
    eq({ vote = 0, isRequired = false }, calls[2].body)
  end)

  it('statuses and policy evaluations', function()
    local api, calls = setup {
      responder = function()
        return nil, { value = { { id = 1 } } }
      end,
    }
    local res = await(function(cb)
      api.list_statuses('r', 5, cb)
    end)
    eq({ { id = 1 } }, res.result)
    eq(P .. '/git/repositories/r/pullRequests/5/statuses', calls[1].url)
    await(function(cb)
      api.list_policy_evaluations('proj-guid', 5, cb)
    end)
    eq(P .. '/policy/evaluations', calls[2].url)
    eq({ artifactId = 'vstfs:///CodeReview/CodeReviewId/proj-guid/5' }, calls[2].query)
    eq('7.1-preview.1', calls[2].api_version)
  end)

  it('get_current_user parses connectionData and caches', function()
    local api, calls = setup {
      responder = function()
        return nil,
          {
            authenticatedUser = {
              id = 'u1',
              providerDisplayName = 'Jan Kowalski',
              properties = { Account = { ['$type'] = 'System.String', ['$value'] = 'jan@x.pl' } },
            },
          }
      end,
    }
    local res = await(api.get_current_user)
    eq({ id = 'u1', name = 'Jan Kowalski', unique_name = 'jan@x.pl' }, res.result)
    eq('https://dev.azure.com/org/_apis/connectionData', calls[1].url)
    eq('7.1-preview', calls[1].api_version)
    res = await(api.get_current_user)
    eq('u1', res.result.id)
    eq(1, #calls, 'cached')
  end)

  it('preview api-versions follow the configured api_version', function()
    local api, calls = setup {
      config = { api_version = '7.0' },
      responder = function()
        return nil, { authenticatedUser = { id = 'u1' }, value = {} }
      end,
    }
    await(api.get_current_user)
    await(function(cb)
      api.list_policy_evaluations('proj-guid', 5, cb)
    end)
    eq('7.0-preview', calls[1].api_version)
    eq('7.0-preview.1', calls[2].api_version)
    api = setup { config = { api_version = '6.0-preview.2' } }
    eq('6.0-preview.1', api._preview_version(1))
  end)

  it('visualstudio.com root', function()
    local api, calls = setup { target = { base_url = 'https://org.visualstudio.com' } }
    await(function(cb)
      api.list_threads('r', 1, cb)
    end)
    eq('https://org.visualstudio.com/My%20Proj/_apis/git/repositories/r/pullRequests/1/threads', calls[1].url)
  end)

  it('web_url for normalized and raw PRs', function()
    local api = setup()
    eq(
      'https://dev.azure.com/org/My%20Proj/_git/my%20repo/pullrequest/12',
      api.web_url({ id = 12, repository = { name = 'my repo', project_name = 'My Proj' } }, TARGET)
    )
    eq(
      'https://dev.azure.com/org/Other/_git/r/pullrequest/3',
      api.web_url({ pullRequestId = 3, repository = { name = 'r', project = { name = 'Other' } } }, TARGET)
    )
    -- no target known -> falls back to raw webUrl
    eq('https://x/_git/r/pullrequest/4', api.web_url { pullRequestId = 4, repository = { name = 'r', webUrl = 'https://x/_git/r' } })
  end)
end)

describe('api (review fixes)', function()
  it('reports truncated = true only when max_prs cut the list short', function()
    local api = setup {
      config = { max_prs = 150 },
      responder = function(_, n)
        return nil, { value = n_prs(100, (n - 1) * 100) }
      end,
    }
    local info
    local done = false
    api.list_pull_requests({}, function(_, _, i)
      info, done = i, true
    end)
    truthy(wait_for(function()
      return done
    end, 2000))
    eq(true, info.truncated)

    api = setup {
      responder = function()
        return nil, { value = n_prs(30) }
      end,
    }
    done = false
    api.list_pull_requests({}, function(_, _, i)
      info, done = i, true
    end)
    truthy(wait_for(function()
      return done
    end, 2000))
    eq(false, info.truncated)
  end)

  it('passes creator_id / reviewer_id as searchCriteria', function()
    local api, calls = setup {}
    await(function(cb)
      api.list_pull_requests({ creator_id = 'me-id' }, cb)
    end)
    eq('me-id', calls[1].query['searchCriteria.creatorId'])
    await(function(cb)
      api.list_pull_requests({ reviewer_id = 'me-id' }, cb)
    end)
    eq('me-id', calls[2].query['searchCriteria.reviewerId'])
  end)

  it('thread body anchors the whole end line via end_offset', function()
    local api = setup {}
    local ctx = api._thread_body({ content = 'x', file_path = 'a.lua', line = 2, end_line = 4, end_offset = 13 }).threadContext
    eq({ line = 2, offset = 1 }, ctx.rightFileStart)
    eq({ line = 4, offset = 13 }, ctx.rightFileEnd)
  end)
end)
