-- Pure normalisation of raw Azure DevOps REST JSON into plugin-friendly tables.
local M = {}

-- util.lua may be written concurrently; fall back to local helpers when it is not available.
local ok_util, util = pcall(require, 'azure_pr.util')
if not ok_util then
  util = nil
end

local function strip_ref(ref)
  if util and util.strip_ref then
    return util.strip_ref(ref)
  end
  if type(ref) ~= 'string' then
    return ref
  end
  return (ref:gsub('^refs/heads/', ''))
end

local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function parse_date(iso)
  if iso == nil or iso == vim.NIL then
    return nil
  end
  if util and util.parse_date then
    return util.parse_date(iso)
  end
  if type(iso) ~= 'string' then
    return nil
  end
  local y, mo, d, h, mi, s = iso:match '^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)'
  if not y then
    return nil
  end
  local epoch = days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
  -- Azure's "0001-01-01T00:00:00" means "not set".
  if tonumber(y) <= 1 then
    return nil
  end
  return epoch
end

local function val(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

local function lower_str(s)
  return type(s) == 'string' and s:lower() or s
end

local function identity(raw)
  raw = val(raw) or {}
  return {
    id = val(raw.id),
    name = val(raw.displayName) or val(raw.uniqueName) or 'Unknown',
    unique_name = val(raw.uniqueName),
  }
end

local function lower(s)
  return type(s) == 'string' and s:lower() or s
end

--- Vote values used by Azure DevOps.
M.VOTES = { approved = 10, approved_suggestions = 5, none = 0, waiting = -5, rejected = -10 }

local VOTE_LABELS = {
  [10] = 'Approved',
  [5] = 'Approved with suggestions',
  [0] = 'No vote',
  [-5] = 'Waiting for author',
  [-10] = 'Rejected',
}

---@param v number|nil
---@return string
function M.vote_label(v)
  return VOTE_LABELS[v] or ('Vote ' .. tostring(v))
end

--- All review states in their logical order (used by filter.group).
M.REVIEW_STATES = { 'rejected', 'waiting', 'no_votes', 'approved_suggestions', 'approved', 'draft', 'completed', 'abandoned' }

--- Compute review state. Rules (evaluated in order):
---  1. status completed/abandoned -> that status
---  2. draft -> 'draft'
---  3. any reviewer vote -10 -> 'rejected'
---  4. any reviewer vote -5 -> 'waiting'
---  5. no positive votes at all -> 'no_votes'
---  6. at least one 10 and every required non-container reviewer voted >= 5 -> 'approved'
---  7. otherwise (positive votes only, but only 5s or a required reviewer still pending) -> 'approved_suggestions'
--- Declined reviewers are ignored for the "required reviewer pending" check.
---@param status string
---@param is_draft boolean
---@param reviewers table
---@return string
function M.compute_review_state(status, is_draft, reviewers)
  if status == 'completed' or status == 'abandoned' then
    return status
  end
  if is_draft then
    return 'draft'
  end
  local has_reject, has_wait, has_10, has_positive = false, false, false, false
  local required_pending = false
  for _, r in ipairs(reviewers or {}) do
    local v = r.vote or 0
    if v <= -10 then
      has_reject = true
    elseif v < 0 then
      has_wait = true
    elseif v > 0 then
      has_positive = true
      if v >= 10 then
        has_10 = true
      end
    end
    if r.is_required and not r.is_container and not r.has_declined and v < 5 then
      required_pending = true
    end
  end
  if has_reject then
    return 'rejected'
  end
  if has_wait then
    return 'waiting'
  end
  if not has_positive then
    return 'no_votes'
  end
  if has_10 and not required_pending then
    return 'approved'
  end
  return 'approved_suggestions'
end

---@param raw table raw Azure DevOps GitPullRequest
---@return AzurePR
function M.normalize_pr(raw)
  raw = raw or {}
  local repo = val(raw.repository) or {}
  local project = val(repo.project) or {}
  local reviewers = {}
  for _, r in ipairs(val(raw.reviewers) or {}) do
    table.insert(reviewers, {
      id = val(r.id),
      name = val(r.displayName) or val(r.uniqueName) or 'Unknown',
      unique_name = val(r.uniqueName),
      vote = tonumber(val(r.vote)) or 0,
      is_required = val(r.isRequired) == true,
      is_container = val(r.isContainer) == true,
      has_declined = val(r.hasDeclined) == true,
    })
  end
  local labels = {}
  for _, l in ipairs(val(raw.labels) or {}) do
    if val(l.active) ~= false and val(l.name) then
      table.insert(labels, l.name)
    end
  end
  local status = val(raw.status) or 'active'
  local is_draft = val(raw.isDraft) == true
  ---@class AzurePR
  local pr = {
    id = val(raw.pullRequestId),
    title = val(raw.title) or '',
    description = val(raw.description) or '',
    status = status,
    is_draft = is_draft,
    merge_status = val(raw.mergeStatus),
    created_at = parse_date(val(raw.creationDate)),
    closed_at = parse_date(val(raw.closedDate)),
    author = identity(raw.createdBy),
    repository = {
      id = val(repo.id),
      name = val(repo.name),
      project_id = val(project.id),
      project_name = val(project.name),
    },
    source_branch = strip_ref(val(raw.sourceRefName)),
    target_branch = strip_ref(val(raw.targetRefName)),
    -- commits of the last merge evaluation: what Azure shows as the PR diff (target...source)
    source_commit = val((val(raw.lastMergeSourceCommit) or {}).commitId),
    target_commit = val((val(raw.lastMergeTargetCommit) or {}).commitId),
    reviewers = reviewers,
    review_state = M.compute_review_state(status, is_draft, reviewers),
    labels = labels,
    url = nil,
    raw = raw,
  }
  return pr
end

---@param raws table[]
---@return AzurePR[]
function M.normalize_prs(raws)
  local out = {}
  for _, r in ipairs(raws or {}) do
    table.insert(out, M.normalize_pr(r))
  end
  return out
end

-- CommentThreadStatus enum
local THREAD_STATUS = { [0] = 'unknown', 'active', 'fixed', 'wontFix', 'closed', 'byDesign', 'pending' }
local THREAD_STATUS_BY_LOWER = {}
for _, s in pairs(THREAD_STATUS) do
  THREAD_STATUS_BY_LOWER[s:lower()] = s
end

--- Thread statuses that can be set by the user.
M.THREAD_STATUSES = { 'active', 'pending', 'fixed', 'wontFix', 'closed', 'byDesign' }

---@param s string|number|nil
---@return string
function M.thread_status(s)
  s = val(s)
  if type(s) == 'number' then
    return THREAD_STATUS[s] or 'unknown'
  end
  if type(s) == 'string' then
    local n = tonumber(s)
    if n then
      return THREAD_STATUS[n] or 'unknown'
    end
    return THREAD_STATUS_BY_LOWER[s:lower()] or s
  end
  return 'unknown'
end

--- true for statuses that count as "open" (active/pending).
---@param status string
function M.is_thread_open(status)
  return status == 'active' or status == 'pending'
end

-- CommentType enum
local COMMENT_TYPE = { [0] = 'unknown', 'text', 'codeChange', 'system' }

local function comment_type(t)
  t = val(t)
  if type(t) == 'number' then
    return COMMENT_TYPE[t] or 'unknown'
  end
  if type(t) == 'string' then
    return t
  end
  return 'text'
end

local function has_property(props, name)
  props = val(props)
  if type(props) ~= 'table' then
    return false
  end
  return val(props[name]) ~= nil
end

---@param raw table raw GitPullRequestCommentThread
function M.normalize_thread(raw)
  raw = raw or {}
  local comments = {}
  for _, c in ipairs(val(raw.comments) or {}) do
    table.insert(comments, {
      id = val(c.id),
      parent_id = val(c.parentCommentId) or 0,
      author = identity(c.author),
      content = val(c.content) or '',
      published_at = parse_date(val(c.publishedDate)),
      updated_at = parse_date(val(c.lastUpdatedDate)),
      is_deleted = val(c.isDeleted) == true,
      type = comment_type(c.commentType),
    })
  end
  table.sort(comments, function(a, b)
    return (a.id or 0) < (b.id or 0)
  end)

  local all_system = #comments > 0
  for _, c in ipairs(comments) do
    if c.type ~= 'system' then
      all_system = false
      break
    end
  end
  local is_system = all_system or has_property(raw.properties, 'CodeReviewThreadType')

  local ctx = val(raw.threadContext)
  local file_path, line, end_line, side
  if type(ctx) == 'table' then
    file_path = val(ctx.filePath)
    -- right = the PR's changed (source) version; left = the base version (e.g. comments on deleted lines)
    local rs, ls = val(ctx.rightFileStart), val(ctx.leftFileStart)
    local s = rs or ls
    local e = rs and val(ctx.rightFileEnd) or (not rs and val(ctx.leftFileEnd)) or nil
    line = s and val(s.line) or nil
    end_line = e and val(e.line) or line
    if s then
      side = rs and 'right' or 'left'
    end
  end

  return {
    id = val(raw.id),
    status = M.thread_status(raw.status),
    is_deleted = val(raw.isDeleted) == true,
    file_path = file_path,
    line = line,
    end_line = end_line,
    side = side, -- 'right' | 'left' | nil (no line anchor)
    is_system = is_system,
    published_at = parse_date(val(raw.publishedDate)),
    updated_at = parse_date(val(raw.lastUpdatedDate)),
    comments = comments,
    raw = raw,
  }
end

--- Normalise, drop deleted (and by default system) threads, sort by published_at (then id).
---@param raws table[]
---@param opts? { include_system?: boolean }
function M.normalize_threads(raws, opts)
  opts = opts or {}
  local out = {}
  for _, r in ipairs(raws or {}) do
    local t = M.normalize_thread(r)
    if not t.is_deleted and (opts.include_system or not t.is_system) then
      table.insert(out, t)
    end
  end
  table.sort(out, function(a, b)
    local pa, pb = a.published_at or 0, b.published_at or 0
    if pa ~= pb then
      return pa < pb
    end
    return (a.id or 0) < (b.id or 0)
  end)
  return out
end

--- Counts shown in the list's comment column, from normalized (non-system) threads:
--- `comments` = non-deleted text comments, `threads` = resolvable threads (any status but
--- 'unknown'), `resolved` = those of them that are not active/pending.
---@param threads table[] result of normalize_threads
---@return { comments: integer, threads: integer, resolved: integer }
function M.thread_stats(threads)
  local s = { comments = 0, threads = 0, resolved = 0 }
  for _, t in ipairs(threads or {}) do
    for _, c in ipairs(t.comments or {}) do
      if not c.is_deleted and c.type ~= 'system' then
        s.comments = s.comments + 1
      end
    end
    if t.status ~= 'unknown' then
      s.threads = s.threads + 1
      if not M.is_thread_open(t.status) then
        s.resolved = s.resolved + 1
      end
    end
  end
  return s
end

-- ---------------------------------------------------------------------------
-- Checks (policy evaluations + PR statuses), shaped like Azure's "Checks" panel
-- ---------------------------------------------------------------------------

-- Well-known policy type ids (the display name is a fallback for localized / on-prem servers).
M.POLICY_TYPES = {
  build = { id = '0609b952-1397-4640-95ec-e00a01b2c241', name = 'Build' },
  min_reviewers = { id = 'fa4e907d-c16b-4a4c-9dfa-4906e5d171dd', name = 'Minimum number of reviewers' },
  required_reviewers = { id = 'fd2167ab-b0be-447a-8ec8-39368250530e', name = 'Required reviewers' },
  comments = { id = 'c6a1889d-b943-4856-b76f-9e46bb6b0df2', name = 'Comment requirements' },
  work_items = { id = '40e92b44-2fe1-4dd6-b3d8-74a9c21d0c6e', name = 'Work item linking' },
  status = { id = 'cbdc66da-9728-4af8-aada-9a5a32e4a226', name = 'Status' },
}

---@param p table raw PolicyEvaluationRecord
---@return string|nil key of M.POLICY_TYPES
function M.policy_kind(p)
  local cfg = val(p and p.configuration) or {}
  local t = val(cfg.type) or {}
  local id, name = lower_str(val(t.id)), val(t.displayName)
  for key, def in pairs(M.POLICY_TYPES) do
    if id == def.id or name == def.name then
      return key
    end
  end
  return nil
end

--- The statuses endpoint returns the whole history (every post, every iteration). Keep only the
--- latest status per context (genre/name): highest iterationId, then latest updated/creation date,
--- then highest id. Order of first appearance is preserved.
---@param statuses table[]|nil raw GitPullRequestStatus list
---@return table[]
function M.latest_statuses(statuses)
  local order, best = {}, {}
  local function newer(a, b)
    local ia, ib = tonumber(a.iterationId) or 0, tonumber(b.iterationId) or 0
    if ia ~= ib then
      return ia > ib
    end
    -- ISO 8601 timestamps compare correctly as strings
    local da, db = tostring(a.updatedDate or a.creationDate or ''), tostring(b.updatedDate or b.creationDate or '')
    if da ~= db then
      return da > db
    end
    return (tonumber(a.id) or 0) > (tonumber(b.id) or 0)
  end
  for i, s in ipairs(statuses or {}) do
    local key
    if type(s.context) == 'table' then
      key = (s.context.genre or '') .. '/' .. (s.context.name or '')
    else
      key = '#' .. i -- no context: cannot tell what it supersedes, keep it
    end
    if not best[key] then
      order[#order + 1] = key
      best[key] = s
    elseif newer(s, best[key]) then
      best[key] = s
    end
  end
  local out = {}
  for _, k in ipairs(order) do
    out[#out + 1] = best[k]
  end
  return out
end

-- check state (render style key) from a policy evaluation status / PR status state
local POLICY_STATE = {
  approved = 'approved',
  rejected = 'rejected',
  running = 'running',
  queued = 'queued',
  broken = 'broken',
  notApplicable = 'notApplicable',
}
local STATUS_STATE = {
  succeeded = 'approved',
  failed = 'rejected',
  error = 'broken',
  pending = 'running',
  notApplicable = 'notApplicable',
  notSet = 'queued',
}
-- Azure's wording under a build check: "<name> succeeded" / "Build succeeded"
local BUILD_VERB = {
  approved = 'succeeded',
  rejected = 'failed',
  running = 'in progress',
  queued = 'queued',
  broken = 'error',
  expired = 'expired',
}
local GENERIC_LABEL = {
  approved = 'Succeeded',
  rejected = 'Failed',
  running = 'Running',
  queued = 'Waiting',
  broken = 'Error',
  expired = 'Expired',
}

local function policy_check(p, kind, definition_names)
  local cfg = val(p.configuration) or {}
  local settings = val(cfg.settings) or {}
  local ctx = val(p.context) or {}
  local state = POLICY_STATE[val(p.status)] or 'queued'
  local c = {
    kind = kind or 'policy',
    state = state,
    is_blocking = val(cfg.isBlocking) ~= false,
    evaluation_id = val(p.evaluationId),
  }
  if kind == 'build' then
    local def_id = tonumber(val(settings.buildDefinitionId))
    local display = val(settings.displayName)
    c.definition_id = def_id
    c.build_id = tonumber(val(ctx.buildId))
    if val(ctx.isExpired) == true and state ~= 'running' and state ~= 'queued' then
      c.state = 'expired'
    end
    c.name = display or (def_id and definition_names and definition_names[def_id]) or ('Build' .. (def_id and (' #' .. def_id) or ''))
    c.label = (display or 'Build') .. ' ' .. (BUILD_VERB[c.state] or c.state)
    c.can_requeue = c.evaluation_id ~= nil
  else
    if kind == 'comments' then
      c.name = 'Comments must be resolved'
    elseif kind == 'work_items' then
      c.name = 'Work items must be linked'
    elseif kind == 'status' then
      local genre, sname = val(settings.statusGenre), val(settings.statusName)
      c.name = val(settings.defaultDisplayName) or (sname and ((genre and genre ~= '' and (genre .. '/') or '') .. sname)) or 'Status'
      c.status_key = (genre or '') .. '/' .. (sname or '')
    else
      c.name = val(settings.displayName) or val((val(cfg.type) or {}).displayName) or 'Policy'
    end
    c.label = GENERIC_LABEL[c.state] or c.state
  end
  return c
end

local function status_check(s)
  local ctx = type(s.context) == 'table' and s.context or {}
  local name = ctx.genre and ctx.genre ~= '' and (ctx.genre .. '/' .. (ctx.name or '')) or ctx.name
  local state = STATUS_STATE[val(s.state)] or 'queued'
  local desc = val(s.description)
  return {
    kind = 'pr_status',
    name = name or desc or 'status',
    state = state,
    label = (name and desc) or GENERIC_LABEL[state] or state,
    is_blocking = false,
    status_key = (ctx.genre or '') .. '/' .. (ctx.name or ''),
    url = val(s.targetUrl),
  }
end

local function is_approval(vote)
  return (tonumber(vote) or 0) >= 5
end

--- Reviewer requirement summary: from the reviewer policies when there are any, else from votes.
local function reviewer_summary(pr, rev_policies)
  local approvals, rejected, waiting_author, pending_required = 0, false, false, {}
  for _, r in ipairs(pr.reviewers or {}) do
    if is_approval(r.vote) and not r.is_container then
      approvals = approvals + 1
    end
    rejected = rejected or r.vote == -10
    waiting_author = waiting_author or r.vote == -5
    if r.is_required and not is_approval(r.vote) then
      pending_required[#pending_required + 1] = r.name
    end
  end
  local min
  local state
  if #rev_policies > 0 then
    state = 'approved'
    for _, rp in ipairs(rev_policies) do
      local p = rp.raw
      local s = POLICY_STATE[val(p.status)] or 'queued'
      if rp.kind == 'min_reviewers' then
        local settings = val((val(p.configuration) or {}).settings) or {}
        min = tonumber(val(settings.minimumApproverCount)) or min
      end
      -- a reviewer policy is 'rejected' while it is not met yet: that is waiting, not a failure
      -- (an actual reject vote turns the line red below)
      if s ~= 'approved' and s ~= 'notApplicable' then
        state = 'running'
      end
    end
  else
    local rs = pr.review_state
    state = (rs == 'approved' or rs == 'approved_suggestions') and 'approved' or rs == 'rejected' and 'rejected' or 'running'
  end
  local label
  if state == 'approved' then
    label = 'Required reviewers approved'
  elseif rejected then
    state = 'rejected'
    label = 'A reviewer rejected the changes'
  elseif waiting_author then
    label = 'A reviewer is waiting for the author'
  else
    label = 'Waiting for reviewers to approve'
  end
  local details = {}
  if min then
    details[#details + 1] = string.format('%d of %d approvals', math.min(approvals, min), min)
  elseif approvals > 0 then
    details[#details + 1] = approvals .. (approvals == 1 and ' approval' or ' approvals')
  end
  if state ~= 'approved' and #pending_required > 0 then
    details[#details + 1] = 'required: ' .. table.concat(pending_required, ', ')
  end
  return { kind = 'reviewers', state = state, label = label, details = details }
end

local MERGE_SUMMARY = {
  succeeded = { 'approved', 'No merge conflicts' },
  conflicts = { 'rejected', 'Merge conflicts' },
  queued = { 'running', 'Checking for merge conflicts' },
  failure = { 'rejected', 'Merge check failed' },
  rejectedByPolicy = { 'rejected', 'Merge rejected by policy' },
}

--- Everything the detail view shows about mergeability, mirroring Azure's PR overview:
--- `reviewers` / `merge` summary lines and the checks split into `required` / `optional`
--- (build, comment, work item and status policies, plus PR statuses not covered by a status
--- policy). Reviewer policies feed the reviewers line instead of a check; policies that do not
--- apply to the PR are dropped, like in Azure.
---@param pr AzurePR
---@param policies table[]|nil raw policy evaluations
---@param statuses table[]|nil raw PR statuses
---@param opts { definition_names: table<integer, string>|nil }|nil
function M.pr_checks(pr, policies, statuses, opts)
  opts = opts or {}
  local out = { required = {}, optional = {}, passed = 0, total = 0 }
  local rev_policies, status_keys = {}, {}
  local function add(c)
    if c.state == 'notApplicable' then
      return
    end
    table.insert(c.is_blocking and out.required or out.optional, c)
    out.total = out.total + 1
    if c.state == 'approved' then
      out.passed = out.passed + 1
    end
  end
  for _, p in ipairs(policies or {}) do
    local cfg = val(p.configuration) or {}
    if val(cfg.isEnabled) ~= false and val(cfg.isDeleted) ~= true then
      local kind = M.policy_kind(p)
      if kind == 'min_reviewers' or kind == 'required_reviewers' then
        rev_policies[#rev_policies + 1] = { raw = p, kind = kind }
      else
        local c = policy_check(p, kind, opts.definition_names)
        if c.status_key then
          status_keys[c.status_key] = true
        end
        add(c)
      end
    end
  end
  for _, s in ipairs(M.latest_statuses(statuses)) do
    local c = status_check(s)
    if not status_keys[c.status_key] then
      add(c)
    end
  end
  out.reviewers = reviewer_summary(pr, rev_policies)
  local ms = MERGE_SUMMARY[pr.merge_status or '']
  out.merge = { kind = 'merge', state = ms and ms[1] or 'notSet', label = ms and ms[2] or 'Merge not checked yet' }
  return out
end

--- Find the reviewer entry for a user (direct reviewer only; ids compared case-insensitively).
---@param pr AzurePR
---@param user_id string|nil
function M.find_reviewer(pr, user_id)
  if not user_id or not pr then
    return nil
  end
  local uid = lower(user_id)
  for _, r in ipairs(pr.reviewers or {}) do
    if r.id and lower(r.id) == uid then
      return r
    end
  end
  return nil
end

---@param pr AzurePR
---@param user_id string|nil
---@return number|nil
function M.my_vote(pr, user_id)
  local r = M.find_reviewer(pr, user_id)
  return r and r.vote or nil
end

--- Is the PR authored by user_id (case-insensitive id compare)?
function M.is_author(pr, user_id)
  return user_id ~= nil and pr and pr.author and pr.author.id ~= nil and lower(pr.author.id) == lower(user_id) or false
end

return M
