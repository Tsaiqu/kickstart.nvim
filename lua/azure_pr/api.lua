-- Thin wrapper around the Azure DevOps REST API (7.1). All async functions take a trailing
-- `cb(err, result)`; callbacks run on the main loop (http.request guarantees `vim.schedule`).
local http = require 'azure_pr.http'

local M = {}

local PAGE_SIZE = 100

---@type table|nil last resolved target (used by `web_url` which is synchronous)
M._target = nil
---@type table|nil cached current user
M._user = nil

local enc = http.url_encode

local function config()
  return require 'azure_pr.config'
end

--- Preview flavour of the configured api_version (on-prem servers may only speak 6.0 / 7.0):
--- `preview_version()` -> '7.1-preview', `preview_version(1)` -> '7.1-preview.1'.
---@param rev integer|nil
---@return string
local function preview_version(rev)
  local ok, cfg = pcall(function()
    return config().get()
  end)
  local base = ok and type(cfg) == 'table' and type(cfg.api_version) == 'string' and cfg.api_version or '7.1'
  base = base:gsub('%-preview.*$', '')
  if base == '' then
    base = '7.1'
  end
  return base .. '-preview' .. (rev and ('.' .. rev) or '')
end
M._preview_version = preview_version

--- Resolve the target (org/project/...) and run fn(target); errors go straight to cb.
local function with_target(cb, fn)
  config().resolve_target(function(err, target)
    if err or not target then
      vim.schedule(function()
        cb(err or 'Could not resolve Azure DevOps organization/project')
      end)
      return
    end
    M._target = target
    fn(target)
  end)
end
M._with_target = with_target

---@param target table
---@return string e.g. https://dev.azure.com/org/My%20Project/_apis
local function project_api(target)
  return http.root_url(target) .. '/' .. enc(target.project) .. '/_apis'
end

local function pr_url(target, repo_id, pr_id)
  return project_api(target) .. '/git/repositories/' .. enc(repo_id) .. '/pullRequests/' .. enc(pr_id)
end

local function threads_url(target, repo_id, pr_id, thread_id)
  local url = pr_url(target, repo_id, pr_id) .. '/threads'
  if thread_id then
    url = url .. '/' .. enc(thread_id)
  end
  return url
end

--- Request and pass `data.value` (or `{}`) to cb.
local function request_value(opts, cb)
  http.request(opts, function(err, data)
    if err then
      return cb(err)
    end
    cb(nil, (type(data) == 'table' and data.value) or {})
  end)
end

local function request_data(opts, cb)
  http.request(opts, function(err, data)
    cb(err, data)
  end)
end

--- Build the searchCriteria query for PR listing.
---@param params table
---@return table
function M._search_query(params)
  local status = params.status or config().get().default_status or 'active'
  local q = { ['searchCriteria.status'] = status }
  if params.creator_id then
    q['searchCriteria.creatorId'] = params.creator_id
  end
  if params.reviewer_id then
    q['searchCriteria.reviewerId'] = params.reviewer_id
  end
  if params.source_ref then
    local ref = params.source_ref
    if not ref:match '^refs/' then
      ref = 'refs/heads/' .. ref
    end
    q['searchCriteria.sourceRefName'] = ref
  end
  if params.target_ref then
    local ref = params.target_ref
    if not ref:match '^refs/' then
      ref = 'refs/heads/' .. ref
    end
    q['searchCriteria.targetRefName'] = ref
  end
  if params.repository_id then
    q['searchCriteria.repositoryId'] = params.repository_id
  end
  return q
end

-- Fetch all pages of `url` (up to `limit` items) and call cb(err, list, truncated).
-- `truncated` is true when fetching stopped because of `limit` while the server may have more.
local function fetch_paged(url, query, limit, cb)
  local results = {}
  local function page(skip)
    local q = vim.deepcopy(query)
    q['$top'] = math.min(PAGE_SIZE, limit - #results)
    q['$skip'] = skip
    http.request({ method = 'GET', url = url, query = q }, function(err, data)
      if err then
        return cb(err)
      end
      local value = (type(data) == 'table' and data.value) or {}
      for _, pr in ipairs(value) do
        if #results >= limit then
          break
        end
        table.insert(results, pr)
      end
      if #value < q['$top'] then
        return cb(nil, results, false)
      end
      if #results >= limit then
        return cb(nil, results, true)
      end
      page(skip + #value)
    end)
  end
  if limit <= 0 then
    return vim.schedule(function()
      cb(nil, results, true)
    end)
  end
  page(0)
end

--- List pull requests.
--- params: `{ status = 'active'|'completed'|'abandoned'|'all', creator_id?, reviewer_id?,
---   repository? (repo name or id -> repository endpoint), repository_id? (GUID -> searchCriteria.repositoryId),
---   source_ref? ('branch' or 'refs/heads/branch'), target_ref? }`.
--- If `params.repository` is nil and `config.repositories` is set, each configured repository is
--- queried (sequentially) and results concatenated; the total is capped at `config.max_prs`.
---@param params table|nil
--- cb's third argument is `{ truncated = boolean }`: true when `max_prs` cut the list short.
---@param cb fun(err: string|nil, prs: table[]|nil, info: { truncated: boolean }|nil)
function M.list_pull_requests(params, cb)
  params = params or {}
  with_target(cb, function(target)
    local cfg = config().get()
    local limit = params.max or cfg.max_prs or 200
    local query = M._search_query(params)
    local repos
    if params.repository then
      repos = { params.repository }
    elseif not params.repository_id and type(target.repositories or cfg.repositories) == 'table' and #(target.repositories or cfg.repositories) > 0 then
      repos = target.repositories or cfg.repositories
    end

    if not repos then
      return fetch_paged(project_api(target) .. '/git/pullrequests', query, limit, function(err, prs, truncated)
        if err then
          return cb(err)
        end
        cb(nil, prs, { truncated = truncated == true })
      end)
    end

    local all, seen = {}, {}
    local truncated = false
    local function next_repo(i)
      if i > #repos then
        return cb(nil, all, { truncated = truncated })
      end
      if #all >= limit then
        return cb(nil, all, { truncated = true })
      end
      local url = project_api(target) .. '/git/repositories/' .. enc(repos[i]) .. '/pullrequests'
      fetch_paged(url, query, limit - #all, function(err, prs, cut)
        if err then
          return cb(string.format('%s (repository %s)', err, repos[i]))
        end
        truncated = truncated or cut == true
        for _, pr in ipairs(prs) do
          local key = pr.pullRequestId or pr
          if not seen[key] then
            seen[key] = true
            table.insert(all, pr)
          end
        end
        next_repo(i + 1)
      end)
    end
    next_repo(1)
  end)
end

--- GET a PR via its repository.
function M.get_pull_request(repo_id, pr_id, cb)
  with_target(cb, function(target)
    request_data({ method = 'GET', url = pr_url(target, repo_id, pr_id) }, cb)
  end)
end

--- GET a PR by id at project level (no repository needed).
function M.get_pull_request_by_id(pr_id, cb)
  with_target(cb, function(target)
    request_data({ method = 'GET', url = project_api(target) .. '/git/pullrequests/' .. enc(pr_id) }, cb)
  end)
end

--- List comment threads of a PR -> raw thread list.
function M.list_threads(repo_id, pr_id, cb)
  with_target(cb, function(target)
    request_value({ method = 'GET', url = threads_url(target, repo_id, pr_id) }, cb)
  end)
end

--- Normalise a file path for threadContext: forward slashes, single leading slash.
---@param path string
---@return string
function M._thread_file_path(path)
  path = path:gsub('\\', '/'):gsub('^%./', ''):gsub('^/+', '')
  return '/' .. path
end

--- Build the POST body for a new thread (exported for tests).
---@param opts { content: string, status: string|nil, file_path: string|nil, line: integer|nil, end_line: integer|nil, end_offset: integer|nil }
--- `end_offset` is the (exclusive, 1-based character) end column on `end_line`; callers pass
--- `#end_line_text + 1` so the whole line is anchored. Defaults to 1 when unknown.
function M._thread_body(opts)
  local body = {
    comments = { { parentCommentId = 0, content = opts.content, commentType = 1 } },
    status = opts.status or 'active',
  }
  if opts.file_path then
    local ctx = { filePath = M._thread_file_path(opts.file_path) }
    if opts.line then
      ctx.rightFileStart = { line = opts.line, offset = 1 }
      ctx.rightFileEnd = { line = opts.end_line or opts.line, offset = opts.end_offset or 1 }
    end
    body.threadContext = ctx
  end
  return body
end

--- Create a new comment thread (general or file-anchored). cb(err, raw_thread)
function M.create_thread(repo_id, pr_id, opts, cb)
  with_target(cb, function(target)
    request_data({ method = 'POST', url = threads_url(target, repo_id, pr_id), body = M._thread_body(opts) }, cb)
  end)
end

--- Reply to a thread. `parent_comment_id` defaults to 1 (the thread's first comment). cb(err, raw_comment)
function M.reply(repo_id, pr_id, thread_id, content, parent_comment_id, cb)
  with_target(cb, function(target)
    request_data({
      method = 'POST',
      url = threads_url(target, repo_id, pr_id, thread_id) .. '/comments',
      body = { content = content, parentCommentId = parent_comment_id or 1, commentType = 1 },
    }, cb)
  end)
end

--- Change a thread's status ('active','fixed','wontFix','closed','byDesign','pending').
function M.update_thread_status(repo_id, pr_id, thread_id, status, cb)
  with_target(cb, function(target)
    request_data({ method = 'PATCH', url = threads_url(target, repo_id, pr_id, thread_id), body = { status = status } }, cb)
  end)
end

--- Edit a comment's content.
function M.update_comment(repo_id, pr_id, thread_id, comment_id, content, cb)
  with_target(cb, function(target)
    request_data({
      method = 'PATCH',
      url = threads_url(target, repo_id, pr_id, thread_id) .. '/comments/' .. enc(comment_id),
      body = { content = content },
    }, cb)
  end)
end

--- Delete a comment.
function M.delete_comment(repo_id, pr_id, thread_id, comment_id, cb)
  with_target(cb, function(target)
    request_data({ method = 'DELETE', url = threads_url(target, repo_id, pr_id, thread_id) .. '/comments/' .. enc(comment_id) }, cb)
  end)
end

--- Vote on a PR: 10 approve, 5 approve with suggestions, 0 reset, -5 wait for author, -10 reject.
--- This PUT replaces the reviewer resource: omitted fields fall back to defaults, so a required
--- reviewer must send `is_required = true` again or Azure silently turns them optional.
--- Signature: `vote(repo_id, pr_id, reviewer_id, vote, [opts], cb)` with
--- `opts = { is_required?: boolean }` (omit opts when the user is not a reviewer yet).
function M.vote(repo_id, pr_id, reviewer_id, vote, opts, cb)
  if cb == nil and type(opts) == 'function' then
    opts, cb = nil, opts
  end
  opts = opts or {}
  local body = { vote = vote }
  if opts.is_required ~= nil then
    body.isRequired = opts.is_required and true or false
  end
  with_target(cb, function(target)
    request_data({ method = 'PUT', url = pr_url(target, repo_id, pr_id) .. '/reviewers/' .. enc(reviewer_id), body = body }, cb)
  end)
end

--- Build/CI statuses posted on a PR -> list.
function M.list_statuses(repo_id, pr_id, cb)
  with_target(cb, function(target)
    request_value({ method = 'GET', url = pr_url(target, repo_id, pr_id) .. '/statuses' }, cb)
  end)
end

--- Policy evaluations (required reviewers, build validation, ...) -> list.
---@param project_id string project GUID (pr.repository.project.id)
function M.list_policy_evaluations(project_id, pr_id, cb)
  with_target(cb, function(target)
    request_value({
      method = 'GET',
      url = project_api(target) .. '/policy/evaluations',
      query = { artifactId = string.format('vstfs:///CodeReview/CodeReviewId/%s/%s', project_id, pr_id) },
      api_version = preview_version(1),
    }, cb)
  end)
end

--- Current authenticated user -> `{ id, name, unique_name }` (cached).
function M.get_current_user(cb)
  if M._user then
    local user = M._user
    return vim.schedule(function()
      cb(nil, user)
    end)
  end
  with_target(cb, function(target)
    http.request({ method = 'GET', url = http.root_url(target) .. '/_apis/connectionData', api_version = preview_version() }, function(err, data)
      if err then
        return cb(err)
      end
      local u = type(data) == 'table' and data.authenticatedUser or nil
      if type(u) ~= 'table' or not u.id then
        return cb 'connectionData response has no authenticatedUser'
      end
      local account = u.properties and u.properties.Account
      local unique = type(account) == 'table' and account['$value'] or nil
      M._user = { id = u.id, name = u.providerDisplayName or u.customDisplayName or unique, unique_name = unique }
      cb(nil, M._user)
    end)
  end)
end

--- Drop cached user/target.
function M.clear_cache()
  M._user = nil
  M._target = nil
end

--- Web URL of a PR (normalized AzurePR or raw Azure JSON). Synchronous: uses `target` if given,
--- else the last resolved target, else static config; falls back to raw `repository.webUrl`.
---@param pr table
---@param target table|nil
---@return string|nil
function M.web_url(pr, target)
  if not pr then
    return nil
  end
  local id = pr.id or pr.pullRequestId
  local repo = pr.repository or {}
  local raw_repo = (pr.raw and pr.raw.repository) or (pr.pullRequestId and pr.repository) or {}
  target = target or M._target
  if not target then
    local ok, cfg = pcall(function()
      return config().get()
    end)
    if ok and cfg and cfg.organization and cfg.project then
      target = cfg
    end
  end
  local project = repo.project_name or (type(repo.project) == 'table' and repo.project.name) or (target and target.project)
  if target and project and repo.name and id then
    return string.format('%s/%s/_git/%s/pullrequest/%s', http.root_url(target), enc(project), enc(repo.name), tostring(id))
  end
  if raw_repo.webUrl and id then
    return raw_repo.webUrl .. '/pullrequest/' .. tostring(id)
  end
  return nil
end

return M
