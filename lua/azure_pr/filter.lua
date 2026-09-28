-- Pure filtering and grouping of normalized AzurePR lists.
local models = require 'azure_pr.models'

local M = {}

---@class AzurePRFilters
---@field text? string          case-insensitive match in title, id, author name, repo name, source branch
---@field author? string        case-insensitive substring of author name / unique name
---@field repository? string    case-insensitive substring of repository name
---@field target_branch? string case-insensitive substring of target branch
--- For author/repository/target_branch a leading '=' means an exact (case-insensitive) match,
--- e.g. `target_branch = '=main'` does not match 'maintenance'. The filter menu stores picked values
--- this way; typed values stay substring matches unless the user types the '='.
---@field draft? boolean        true = drafts only, false = non-drafts only, nil = don't care
---@field created_by_me? boolean  true = only mine (false/nil = don't care)
---@field reviewer_is_me? boolean true = only where I'm a direct reviewer (false/nil = don't care)
---@field needs_my_vote? boolean  true = I'm a direct reviewer, my vote is 0, PR active & not draft
---@field review_state? string  exact review_state match

M.GROUP_BY = { 'none', 'repository', 'author', 'review_state', 'target_branch', 'my_vote' }

M.REVIEW_STATE_LABELS = {
  rejected = 'Rejected',
  waiting = 'Waiting for author',
  no_votes = 'No votes',
  approved_suggestions = 'Approved with suggestions',
  approved = 'Approved',
  draft = 'Draft',
  completed = 'Completed',
  abandoned = 'Abandoned',
}

local function nonempty(s)
  return type(s) == 'string' and s ~= ''
end

local function icontains(haystack, needle)
  if haystack == nil then
    return false
  end
  return tostring(haystack):lower():find(needle:lower(), 1, true) ~= nil
end

--- Substring match, or exact match when `needle` starts with '=' (both case-insensitive).
local function value_matches(haystack, needle)
  if haystack == nil then
    return false
  end
  if needle:sub(1, 1) == '=' and #needle > 1 then
    return tostring(haystack):lower() == needle:sub(2):lower()
  end
  return icontains(haystack, needle)
end
M._value_matches = value_matches

local function matches_text(pr, text)
  local fields = {
    pr.title,
    pr.id and tostring(pr.id),
    pr.author and pr.author.name,
    pr.repository and pr.repository.name,
    pr.source_branch,
  }
  for i = 1, 5 do
    if icontains(fields[i], text) then
      return true
    end
  end
  -- allow searching '!123'
  if text:sub(1, 1) == '!' and pr.id and tostring(pr.id) == text:sub(2) then
    return true
  end
  return false
end

---@param pr AzurePR
---@param user_id string|nil
function M.needs_vote(pr, user_id)
  return pr.status == 'active' and not pr.is_draft and models.my_vote(pr, user_id) == 0
end

---@param pr AzurePR
---@param f AzurePRFilters
---@param ctx table
local function keep(pr, f, ctx)
  local uid = ctx.user_id
  if nonempty(f.text) and not matches_text(pr, f.text) then
    return false
  end
  if nonempty(f.author) and not (value_matches(pr.author and pr.author.name, f.author) or value_matches(pr.author and pr.author.unique_name, f.author)) then
    return false
  end
  if nonempty(f.repository) and not value_matches(pr.repository and pr.repository.name, f.repository) then
    return false
  end
  if nonempty(f.target_branch) and not value_matches(pr.target_branch, f.target_branch) then
    return false
  end
  if f.draft ~= nil and (pr.is_draft == true) ~= f.draft then
    return false
  end
  -- Without a known user id, "me" filters cannot match anything.
  if f.created_by_me and not models.is_author(pr, uid) then
    return false
  end
  if f.reviewer_is_me and not models.find_reviewer(pr, uid) then
    return false
  end
  if f.needs_my_vote and not M.needs_vote(pr, uid) then
    return false
  end
  if nonempty(f.review_state) and pr.review_state ~= f.review_state then
    return false
  end
  return true
end

---@param prs AzurePR[]
---@param filters AzurePRFilters|nil
---@param ctx? { user_id?: string }
---@return AzurePR[]
function M.apply(prs, filters, ctx)
  filters = filters or {}
  ctx = ctx or {}
  local out = {}
  for _, pr in ipairs(prs or {}) do
    if keep(pr, filters, ctx) then
      table.insert(out, pr)
    end
  end
  return out
end

local function sort_items(items)
  table.sort(items, function(a, b)
    local ca, cb = a.created_at or 0, b.created_at or 0
    if ca ~= cb then
      return ca > cb
    end
    return (a.id or 0) > (b.id or 0)
  end)
end

local STATE_ORDER = {}
for i, s in ipairs(models.REVIEW_STATES) do
  STATE_ORDER[s] = i
end

--- Returns key, label for a PR under the given grouping.
local function key_of(pr, group_by, ctx)
  if group_by == 'repository' then
    local name = pr.repository and pr.repository.name or 'Unknown repository'
    return name, name
  elseif group_by == 'author' then
    local a = pr.author or {}
    local label = a.name or 'Unknown'
    return a.id or a.unique_name or label, label
  elseif group_by == 'review_state' then
    local s = pr.review_state or 'no_votes'
    return s, M.REVIEW_STATE_LABELS[s] or s
  elseif group_by == 'target_branch' then
    local b = pr.target_branch or '?'
    return b, b
  elseif group_by == 'my_vote' then
    local v = models.my_vote(pr, ctx.user_id)
    if v == nil then
      return 'none', 'Not a reviewer'
    end
    return tostring(v), models.vote_label(v)
  end
  return '', 'All'
end

---@param prs AzurePR[]
---@param group_by string one of M.GROUP_BY (unknown values behave like 'none')
---@param ctx? { user_id?: string }
---@return { key: string, label: string, items: AzurePR[] }[]
function M.group(prs, group_by, ctx)
  ctx = ctx or {}
  group_by = group_by or 'none'
  if not vim.tbl_contains(M.GROUP_BY, group_by) then
    group_by = 'none'
  end
  if group_by == 'none' then
    local items = vim.list_extend({}, prs or {})
    sort_items(items)
    return { { key = '', label = 'All', items = items } }
  end
  local groups, by_key = {}, {}
  for _, pr in ipairs(prs or {}) do
    local key, label = key_of(pr, group_by, ctx)
    local g = by_key[key]
    if not g then
      g = { key = key, label = label, items = {} }
      by_key[key] = g
      table.insert(groups, g)
    end
    table.insert(g.items, pr)
  end
  for _, g in ipairs(groups) do
    sort_items(g.items)
  end
  table.sort(groups, function(a, b)
    if group_by == 'review_state' then
      local oa, ob = STATE_ORDER[a.key] or 99, STATE_ORDER[b.key] or 99
      if oa ~= ob then
        return oa < ob
      end
    end
    local la, lb = a.label:lower(), b.label:lower()
    if la ~= lb then
      return la < lb
    end
    return a.key < b.key
  end)
  return groups
end

---@param filters AzurePRFilters|nil
---@return boolean
function M.is_empty(filters)
  return M.describe(filters) == ''
end

---@param filters AzurePRFilters|nil
---@return string
function M.describe(filters)
  local f = filters or {}
  local parts = {}
  if nonempty(f.text) then
    table.insert(parts, string.format('text:%q', f.text))
  end
  if nonempty(f.author) then
    table.insert(parts, 'author:' .. f.author)
  end
  if nonempty(f.repository) then
    table.insert(parts, 'repo:' .. f.repository)
  end
  if nonempty(f.target_branch) then
    table.insert(parts, 'target:' .. f.target_branch)
  end
  if f.draft ~= nil then
    table.insert(parts, 'draft:' .. (f.draft and 'yes' or 'no'))
  end
  if f.created_by_me then
    table.insert(parts, 'mine')
  end
  if f.reviewer_is_me then
    table.insert(parts, 'reviewer:me')
  end
  if f.needs_my_vote then
    table.insert(parts, 'needs-my-vote')
  end
  if nonempty(f.review_state) then
    table.insert(parts, 'state:' .. f.review_state)
  end
  return table.concat(parts, ' ')
end

return M
