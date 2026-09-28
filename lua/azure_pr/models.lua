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
