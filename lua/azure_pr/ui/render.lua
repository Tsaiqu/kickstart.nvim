-- Pure rendering: turns normalized data into { lines, highlights, items }.
-- No buffer IO happens here; ui/list.lua and ui/detail.lua apply the result.
--
-- Result:
--   lines      = { string, ... }                        (never contain '\n' / '\r')
--   highlights = { { line0, col_start, col_end, group } } (byte columns, col_end -1 = eol)
--   items      = { [lnum1] = { kind = ..., pr = ?, group_key = ?, thread = ?, comment = ? } }
local M = {}

local function icons_for(opts)
  if opts and opts.icons then
    return opts.icons
  end
  return require('azure_pr.ui.highlights').icons()
end

local function dw(s)
  return vim.fn.strdisplaywidth(s)
end

--- Replace any line breaks / tabs with spaces so the string is a single line.
local function oneline(s)
  if s == nil then
    return ''
  end
  s = tostring(s)
  return (s:gsub('\r\n', ' '):gsub('[\r\n]', ' '):gsub('\t', '  '))
end

--- Split into lines (normalises \r\n and \r), tabs expanded.
local function split(s)
  if s == nil or s == '' then
    return {}
  end
  s = tostring(s):gsub('\r\n', '\n'):gsub('\r', '\n'):gsub('\t', '    ')
  return vim.split(s, '\n', { plain = true })
end

--- Truncate to a display width, adding an ellipsis when cut.
local function truncate(s, width, ellipsis)
  ellipsis = ellipsis or '…'
  if width <= 0 then
    return ''
  end
  if dw(s) <= width then
    return s
  end
  local ew = dw(ellipsis)
  if width <= ew then
    return ellipsis
  end
  local out, cur = {}, 0
  local chars = vim.fn.split(s, '\\zs')
  for _, ch in ipairs(chars) do
    local w = dw(ch)
    if cur + w > width - ew then
      break
    end
    out[#out + 1] = ch
    cur = cur + w
  end
  return table.concat(out) .. ellipsis
end

local function pad(s, width)
  local w = dw(s)
  if w >= width then
    return s
  end
  return s .. string.rep(' ', width - w)
end

--- '3d ago' | '5h ago' | '2m ago' | 'just now' (same format as util.relative_time).
local function relative_time(epoch, now)
  if not epoch then
    return ''
  end
  local diff = (now or os.time()) - epoch
  if diff < 60 then
    return 'just now'
  elseif diff < 3600 then
    return math.floor(diff / 60) .. 'm ago'
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. 'h ago'
  end
  return math.floor(diff / 86400) .. 'd ago'
end

local function date_format(opts)
  if opts.date_format then
    return opts.date_format
  end
  local ok, config = pcall(require, 'azure_pr.config')
  if ok and type(config) == 'table' and type(config.get) == 'function' then
    local ok2, cfg = pcall(config.get)
    if ok2 and type(cfg) == 'table' and cfg.date_format then
      return cfg.date_format
    end
  end
  return '%Y-%m-%d %H:%M'
end

--- Line builder. Each line is made of segments { text, group|nil }.
local function builder()
  local b = { lines = {}, highlights = {}, items = {} }

  ---@param segments table|string list of { text, group } or plain strings (or a single string)
  ---@param item table|nil
  function b.add(segments, item)
    if type(segments) == 'string' then
      segments = { { segments } }
    end
    local parts, col = {}, 0
    local lnum0 = #b.lines
    for _, seg in ipairs(segments) do
      if type(seg) == 'string' then
        seg = { seg }
      end
      local text = oneline(seg[1])
      if seg[2] and #text > 0 then
        b.highlights[#b.highlights + 1] = { lnum0, col, col + #text, seg[2] }
      end
      parts[#parts + 1] = text
      col = col + #text
    end
    b.lines[#b.lines + 1] = table.concat(parts)
    if item then
      b.items[#b.lines] = item
    end
  end

  --- Highlight a whole line (col_end -1 = eol).
  function b.add_line_hl(group)
    b.highlights[#b.highlights + 1] = { #b.lines - 1, 0, -1, group }
  end

  function b.blank()
    b.add ''
  end

  function b.result()
    return { lines = b.lines, highlights = b.highlights, items = b.items }
  end

  return b
end

-- review_state -> icon key + highlight group
local STATE_STYLE = {
  approved = { 'approved', 'AzurePRApproved' },
  approved_suggestions = { 'approved', 'AzurePRApproved' },
  rejected = { 'rejected', 'AzurePRRejected' },
  waiting = { 'waiting', 'AzurePRWaiting' },
  no_votes = { 'no_vote', 'AzurePRNoVote' },
  draft = { 'draft', 'AzurePRDraft' },
  completed = { 'completed', 'AzurePRApproved' },
  abandoned = { 'abandoned', 'AzurePRMuted' },
}

local STATE_LABEL = {
  approved = 'Approved',
  approved_suggestions = 'Approved with suggestions',
  rejected = 'Rejected',
  waiting = 'Waiting for author',
  no_votes = 'No votes',
  draft = 'Draft',
  completed = 'Completed',
  abandoned = 'Abandoned',
}

local function state_style(pr, icons)
  local s = STATE_STYLE[pr.review_state or ''] or STATE_STYLE.no_votes
  return icons[s[1]] or '?', s[2]
end

-- vote -> icon key, group, label (kept local so render does not depend on models.lua)
local function vote_style(vote)
  vote = tonumber(vote) or 0
  if vote >= 10 then
    return 'approved', 'AzurePRApproved', 'Approved'
  elseif vote >= 5 then
    return 'approved', 'AzurePRApproved', 'Approved with suggestions'
  elseif vote <= -10 then
    return 'rejected', 'AzurePRRejected', 'Rejected'
  elseif vote <= -5 then
    return 'waiting', 'AzurePRWaiting', 'Waiting for author'
  end
  return 'no_vote', 'AzurePRNoVote', 'No vote'
end

--------------------------------------------------------------------------------
-- PR list
--------------------------------------------------------------------------------

-- Hint line entries: { keymap action name, label, default lhs (used when no keymap table is given) }
local HINT_SPEC = {
  list = {
    { 'open', 'open', '<CR>' },
    { 'text_filter', 'filter', '/' },
    { 'filter_menu', 'filters', 'F' },
    { 'group_by', 'group', 'gb' },
    { 'status', 'status', 's' },
    { 'toggle_mine', 'mine', 'm' },
    { 'toggle_needs_vote', 'review', 'r' },
    { 'refresh', 'refresh', 'R' },
    { 'help', 'help', '?' },
  },
  detail = {
    { 'comment', 'comment', 'c' },
    { 'reply', 'reply', 'r' },
    { 'thread_status', 'status', 's' },
    { 'toggle_resolved', 'resolved', 't' },
    { 'toggle_thread', 'fold', 'za' },
    { 'vote', 'vote', 'A' },
    { 'browser', 'browser', 'o' },
    { 'refresh', 'refresh', 'R' },
    { 'help', 'help', '?' },
  },
}

local function first_lhs(v)
  if type(v) == 'table' then
    v = v[1]
  end
  return type(v) == 'string' and v ~= '' and v or nil
end

--- Hint entries `{ lhs, label }` built from a keymap table (config.keymaps.list / .detail):
--- the first lhs of each action, disabled actions (false) skipped. `maps == nil` = defaults.
---@param kind 'list'|'detail'
---@param maps table|nil
---@return table[]
function M.hints(kind, maps)
  local out = {}
  for _, h in ipairs(HINT_SPEC[kind] or {}) do
    local lhs
    if maps == nil then
      lhs = h[3]
    else
      lhs = first_lhs(maps[h[1]])
    end
    if lhs then
      out[#out + 1] = { lhs, h[2] }
    end
  end
  return out
end

--- 'Press R to retry, q to close.' with the configured keys (parts omitted when unmapped).
---@param maps table|nil keymap table (list or detail)
---@return string
function M.retry_hint(maps)
  maps = maps or {}
  local parts = {}
  local refresh, close = first_lhs(maps.refresh), first_lhs(maps.close)
  if refresh then
    parts[#parts + 1] = refresh .. ' to retry'
  end
  if close then
    parts[#parts + 1] = close .. ' to close'
  end
  if #parts == 0 then
    return 'Use :AzurePR refresh to retry.'
  end
  return 'Press ' .. table.concat(parts, ', ') .. '.'
end

local function hint_segments(hints)
  local segs = { { ' ' } }
  for i, h in ipairs(hints) do
    if i > 1 then
      segs[#segs + 1] = { '  ' }
    end
    segs[#segs + 1] = { h[1], 'AzurePRKey' }
    segs[#segs + 1] = { ' ' .. h[2], 'AzurePRMuted' }
  end
  return segs
end

---@param groups table list of { key, label, items } (from filter.group)
---@param opts table|nil { collapsed, filters_desc, group_by, status, total, truncated, width, now, icons, hints }
---@return table { lines, highlights, items }
function M.pr_list(groups, opts)
  opts = opts or {}
  groups = groups or {}
  local icons = icons_for(opts)
  local collapsed = opts.collapsed or {}
  local now = opts.now or os.time()
  local arrow = ' ' .. (icons.arrow or '->') .. ' '
  local b = builder()

  local shown = 0
  for _, g in ipairs(groups) do
    shown = shown + #(g.items or {})
  end

  -- header
  local header = { { ' Azure DevOps PRs', 'AzurePRHeader' } }
  header[#header + 1] = { '  ' }
  header[#header + 1] = { '[' .. (opts.status or 'active') .. ']', 'AzurePRKey' }
  if opts.group_by then
    header[#header + 1] = { '  group: ', 'AzurePRMuted' }
    header[#header + 1] = { opts.group_by, 'AzurePRGroup' }
  end
  if opts.filters_desc and opts.filters_desc ~= '' then
    header[#header + 1] = { '  filter: ', 'AzurePRMuted' }
    header[#header + 1] = { opts.filters_desc, 'AzurePRKey' }
  end
  local count = tostring(shown)
  if opts.total then
    count = count .. '/' .. tostring(opts.total) .. (opts.truncated and '+' or '')
  end
  header[#header + 1] = { '  (' .. count .. ')', 'AzurePRMuted' }
  if opts.truncated then
    header[#header + 1] = { '  max_prs reached, older PRs not loaded', 'AzurePRWaiting' }
  end
  b.add(header, { kind = 'header' })
  b.add(hint_segments(opts.hints or M.hints 'list'), { kind = 'hint' })
  b.blank()

  if shown == 0 then
    b.add { { '  No pull requests' .. ((opts.filters_desc and opts.filters_desc ~= '') and ' match the filters' or ''), 'AzurePRMuted' } }
    return b.result()
  end

  -- column widths over all visible rows
  local rows = {}
  local w_id, w_author, w_branch, w_age, w_title = 0, 0, 0, 0, 0
  for _, g in ipairs(groups) do
    if not collapsed[g.key] then
      for _, pr in ipairs(g.items or {}) do
        local r = {
          id = '!' .. tostring(pr.id or '?'),
          title = oneline(pr.title),
          author = truncate(oneline(pr.author and pr.author.name or ''), 24),
          branch = truncate(oneline(pr.source_branch or '') .. arrow .. oneline(pr.target_branch or ''), 48),
          age = relative_time(pr.created_at, now),
        }
        rows[pr] = r
        w_id = math.max(w_id, dw(r.id))
        w_author = math.max(w_author, dw(r.author))
        w_branch = math.max(w_branch, dw(r.branch))
        w_age = math.max(w_age, dw(r.age))
        w_title = math.max(w_title, dw(r.title))
      end
    end
  end
  -- '  ' icon ' ' id '  ' title '  ' author '  ' branch '  ' age
  local icon_w = math.max(dw(icons.approved or '+'), 1)
  if opts.width then
    local fixed = 2 + icon_w + 1 + w_id + 2 + 2 + w_author + 2 + w_branch + 2 + w_age
    w_title = math.max(20, math.min(w_title, opts.width - fixed))
  else
    w_title = math.min(w_title, 60)
  end

  for _, g in ipairs(groups) do
    local is_collapsed = collapsed[g.key] and true or false
    local n = #(g.items or {})
    b.add({
      { (is_collapsed and icons.collapsed or icons.expanded) .. ' ', 'AzurePRGroup' },
      { oneline(g.label or g.key or ''), 'AzurePRGroup' },
      { ' (' .. n .. ')', 'AzurePRMuted' },
    }, { kind = 'group', group_key = g.key, group = g, collapsed = is_collapsed })
    if not is_collapsed then
      for _, pr in ipairs(g.items or {}) do
        local r = rows[pr]
        local icon, icon_hl = state_style(pr, icons)
        local title_hl = pr.is_draft and 'AzurePRDraft' or nil
        b.add({
          { '  ' },
          { pad(icon, icon_w), icon_hl },
          { ' ' },
          { pad(r.id, w_id), 'AzurePRId' },
          { '  ' },
          { pad(truncate(r.title, w_title), w_title), title_hl },
          { '  ' },
          { pad(r.author, w_author), 'AzurePRAuthor' },
          { '  ' },
          { pad(r.branch, w_branch), 'AzurePRBranch' },
          { '  ' },
          { r.age, 'AzurePRMuted' },
        }, { kind = 'pr', pr = pr, group_key = g.key })
        -- strip trailing padding (age may be shorter than column)
        local stripped = b.lines[#b.lines]:gsub('%s+$', '')
        b.lines[#b.lines] = stripped
        for i = #b.highlights, 1, -1 do
          local h = b.highlights[i]
          if h[1] ~= #b.lines - 1 then
            break
          end
          h[3] = math.min(h[3], #stripped)
          if h[3] <= h[2] then
            table.remove(b.highlights, i)
          end
        end
      end
    end
  end

  return b.result()
end

--------------------------------------------------------------------------------
-- PR detail
--------------------------------------------------------------------------------

local OPEN_STATUSES = { active = true, pending = true, unknown = true }

local function is_open(thread)
  return OPEN_STATUSES[thread.status or 'active'] == true or thread.status == nil
end

-- status/policy normalisation (inputs are raw Azure tables from api.lua)
local CHECK_STYLE = {
  succeeded = { 'approved', 'AzurePRApproved' },
  approved = { 'approved', 'AzurePRApproved' },
  failed = { 'rejected', 'AzurePRRejected' },
  error = { 'rejected', 'AzurePRRejected' },
  rejected = { 'rejected', 'AzurePRRejected' },
  broken = { 'rejected', 'AzurePRRejected' },
  pending = { 'waiting', 'AzurePRWaiting' },
  running = { 'waiting', 'AzurePRWaiting' },
  queued = { 'waiting', 'AzurePRWaiting' },
  notApplicable = { 'no_vote', 'AzurePRMuted' },
  notSet = { 'no_vote', 'AzurePRMuted' },
}

local function status_check(s)
  local name = s.name
  if not name and s.context then
    name = s.context.genre and s.context.genre ~= '' and (s.context.genre .. '/' .. (s.context.name or '')) or s.context.name
  end
  name = name or s.description or 'status'
  return { name = name, state = s.state or s.status or 'notSet', description = s.context and s.description or nil }
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

local function policy_check(p)
  local name = p.name
  local cfg = p.configuration
  if not name and cfg then
    name = (cfg.settings and cfg.settings.displayName) or (cfg.type and cfg.type.displayName)
  end
  return { name = name or 'policy', state = p.status or p.state or 'notSet', is_blocking = cfg and cfg.isBlocking }
end

--- Build comment tree order: list of { comment, depth } (depth-first by parent_id).
local function comment_tree(comments)
  local by_id, children, roots = {}, {}, {}
  for _, c in ipairs(comments or {}) do
    if c.id ~= nil then
      by_id[c.id] = c
    end
  end
  for _, c in ipairs(comments or {}) do
    local p = c.parent_id
    if p and p ~= 0 and by_id[p] and p ~= c.id then
      children[p] = children[p] or {}
      table.insert(children[p], c)
    else
      table.insert(roots, c)
    end
  end
  local out, seen = {}, {}
  local function walk(c, depth)
    if seen[c] then
      return
    end
    seen[c] = true
    out[#out + 1] = { c, depth }
    for _, ch in ipairs(children[c.id] or {}) do
      walk(ch, depth + 1)
    end
  end
  for _, c in ipairs(roots) do
    walk(c, 0)
  end
  return out
end

local function thread_location(thread)
  if thread.file_path and thread.file_path ~= '' then
    local path = thread.file_path:gsub('^/', '')
    if thread.line then
      local loc = path .. ':' .. thread.line
      if thread.end_line and thread.end_line ~= thread.line then
        loc = loc .. '-' .. thread.end_line
      end
      if thread.side == 'left' then
        loc = loc .. ' (base)'
      end
      return loc, true
    end
    return path, true
  end
  return 'General', false
end

---@param pr table AzurePR
---@param threads table|nil list of normalized threads
---@param opts table|nil { statuses, policies, user_id, now, show_resolved = true, folded = { [thread_id] = true }, icons, date_format,
---  hints, threads_loading (threads not fetched yet), threads_error (last threads fetch failed), keymaps (detail keymap table) }
---@return table { lines, highlights, items }
function M.pr_detail(pr, threads, opts)
  opts = opts or {}
  threads = threads or {}
  local icons = icons_for(opts)
  local now = opts.now or os.time()
  local folded = opts.folded or {}
  local show_resolved = opts.show_resolved ~= false
  local dot = ' ' .. (icons.dot or '-') .. ' '
  local b = builder()
  local pr_item = { kind = 'pr', pr = pr }

  -- title
  b.add({ { '!' .. tostring(pr.id or '?'), 'AzurePRId' }, { ' ' }, { oneline(pr.title), 'AzurePRTitle' } }, pr_item)
  b.add(hint_segments(opts.hints or M.hints 'detail'), { kind = 'hint', pr = pr })
  b.blank()

  -- meta
  local meta = {}
  local status = pr.status or 'active'
  local status_segs = { { status, status == 'active' and 'AzurePRWaiting' or status == 'completed' and 'AzurePRApproved' or 'AzurePRMuted' } }
  if pr.is_draft then
    status_segs[#status_segs + 1] = { ' (draft)', 'AzurePRDraft' }
  end
  meta[#meta + 1] = { 'Status', status_segs }
  if pr.review_state then
    local icon, hl = state_style(pr, icons)
    meta[#meta + 1] = { 'Review', { { icon .. ' ' .. (STATE_LABEL[pr.review_state] or pr.review_state), hl } } }
  end
  if pr.author then
    meta[#meta + 1] = { 'Author', { { oneline(pr.author.name or pr.author.unique_name or ''), 'AzurePRAuthor' } } }
  end
  if pr.repository then
    meta[#meta + 1] = { 'Repository', { { oneline(pr.repository.name or ''), 'AzurePRBranch' } } }
  end
  meta[#meta + 1] = {
    'Branches',
    { { oneline(pr.source_branch or '?'), 'AzurePRBranch' }, { ' ' .. (icons.arrow or '->') .. ' ' }, { oneline(pr.target_branch or '?'), 'AzurePRBranch' } },
  }
  if pr.created_at then
    meta[#meta + 1] = {
      'Created',
      { { os.date(date_format(opts), pr.created_at) }, { ' (' .. relative_time(pr.created_at, now) .. ')', 'AzurePRMuted' } },
    }
  end
  if pr.closed_at then
    meta[#meta + 1] = { 'Closed', { { os.date(date_format(opts), pr.closed_at) } } }
  end
  if pr.merge_status and pr.merge_status ~= '' then
    local ms = pr.merge_status
    local hl = (ms == 'succeeded') and 'AzurePRApproved'
      or (ms == 'conflicts' or ms == 'failure' or ms == 'rejectedByPolicy') and 'AzurePRRejected'
      or 'AzurePRMuted'
    meta[#meta + 1] = { 'Merge', { { oneline(ms), hl } } }
  end
  if pr.labels and #pr.labels > 0 then
    meta[#meta + 1] = { 'Labels', { { oneline(table.concat(pr.labels, ', ')), 'AzurePRKey' } } }
  end
  if pr.url then
    meta[#meta + 1] = { 'URL', { { oneline(pr.url), 'AzurePRMuted' } } }
  end
  local key_w = 0
  for _, m in ipairs(meta) do
    key_w = math.max(key_w, dw(m[1]))
  end
  for _, m in ipairs(meta) do
    local segs = { { '  ' }, { pad(m[1] .. ':', key_w + 1), 'AzurePRKey' }, { ' ' } }
    vim.list_extend(segs, m[2])
    b.add(segs, { kind = 'meta', pr = pr, key = m[1] })
  end

  -- reviewers
  local reviewers = pr.reviewers or {}
  b.blank()
  b.add({ { 'Reviewers', 'AzurePRHeader' }, { ' (' .. #reviewers .. ')', 'AzurePRMuted' } }, { kind = 'section', section = 'reviewers', pr = pr })
  if #reviewers == 0 then
    b.add { { '  (none)', 'AzurePRMuted' } }
  else
    local name_w = 0
    for _, r in ipairs(reviewers) do
      name_w = math.max(name_w, dw(truncate(oneline(r.name or r.unique_name or '?'), 40)))
    end
    for _, r in ipairs(reviewers) do
      local key, hl, label = vote_style(r.vote)
      local name = truncate(oneline(r.name or r.unique_name or '?'), 40)
      local segs = {
        { '  ' },
        { icons[key] or '?', hl },
        { ' ' },
        { pad(name, name_w), 'AzurePRAuthor' },
        { '  ' },
        { label, hl },
      }
      local tags = {}
      if r.is_required then
        tags[#tags + 1] = 'required'
      end
      if r.is_container then
        tags[#tags + 1] = 'group'
      end
      if r.has_declined then
        tags[#tags + 1] = 'declined'
      end
      if opts.user_id and r.id == opts.user_id then
        tags[#tags + 1] = 'you'
      end
      if #tags > 0 then
        segs[#segs + 1] = { '  (' .. table.concat(tags, ', ') .. ')', 'AzurePRMuted' }
      end
      b.add(segs, { kind = 'reviewer', pr = pr, reviewer = r })
    end
  end

  -- checks
  local checks = {}
  for _, s in ipairs(M.latest_statuses(opts.statuses)) do
    checks[#checks + 1] = status_check(s)
  end
  for _, p in ipairs(opts.policies or {}) do
    checks[#checks + 1] = policy_check(p)
  end
  if #checks > 0 then
    b.blank()
    b.add({ { 'Checks', 'AzurePRHeader' }, { ' (' .. #checks .. ')', 'AzurePRMuted' } }, { kind = 'section', section = 'checks', pr = pr })
    local name_w = 0
    for _, c in ipairs(checks) do
      c.name = truncate(oneline(c.name), 50)
      name_w = math.max(name_w, dw(c.name))
    end
    for _, c in ipairs(checks) do
      local st = CHECK_STYLE[c.state] or { 'no_vote', 'AzurePRMuted' }
      local segs = { { '  ' }, { icons[st[1]] or '?', st[2] }, { ' ' }, { pad(c.name, name_w) }, { '  ' }, { oneline(c.state), st[2] } }
      if c.is_blocking == false then
        segs[#segs + 1] = { '  (optional)', 'AzurePRMuted' }
      end
      b.add(segs, { kind = 'check', pr = pr, check = c })
    end
  end

  -- description
  b.blank()
  b.add({ { 'Description', 'AzurePRHeader' } }, { kind = 'section', section = 'description', pr = pr })
  local desc = split(pr.description)
  if #desc == 0 then
    b.add({ { '  (no description)', 'AzurePRMuted' } }, { kind = 'description', pr = pr })
  else
    for _, l in ipairs(desc) do
      b.add((l == '' and '' or '  ' .. l), { kind = 'description', pr = pr })
    end
  end

  -- threads
  local open_n, visible, hidden = 0, {}, 0
  for _, t in ipairs(threads) do
    local o = is_open(t)
    if o then
      open_n = open_n + 1
    end
    if o or show_resolved then
      visible[#visible + 1] = t
    else
      hidden = hidden + 1
    end
  end
  b.blank()
  b.add({ { 'Threads', 'AzurePRHeader' }, { ' (' .. open_n .. '/' .. #threads .. ')', 'AzurePRMuted' } }, { kind = 'section', section = 'threads', pr = pr })
  local km = opts.keymaps
  local comment_key = km == nil and 'c' or first_lhs(km.comment)
  local refresh_key = km == nil and 'R' or first_lhs(km.refresh)
  local resolved_key = km == nil and 't' or first_lhs(km.toggle_resolved)
  if opts.threads_error then
    local segs = { { '  Failed to load threads: ' .. oneline(opts.threads_error), 'AzurePRRejected' } }
    if refresh_key then
      segs[#segs + 1] = { ' (' }
      segs[#segs + 1] = { refresh_key, 'AzurePRKey' }
      segs[#segs + 1] = { ' to retry)', 'AzurePRMuted' }
    end
    b.add(segs, { kind = 'threads_error', pr = pr })
  end
  if #threads == 0 then
    if opts.threads_loading then
      b.add { { '  Loading comments…', 'AzurePRMuted' } }
    elseif not opts.threads_error then
      if comment_key then
        b.add { { '  No comments yet ', 'AzurePRMuted' }, { comment_key, 'AzurePRKey' }, { ' to add one', 'AzurePRMuted' } }
      else
        b.add { { '  No comments yet', 'AzurePRMuted' } }
      end
    end
  elseif hidden > 0 then
    if resolved_key then
      b.add { { '  ' .. hidden .. ' resolved hidden ', 'AzurePRMuted' }, { resolved_key, 'AzurePRKey' }, { ' to show', 'AzurePRMuted' } }
    else
      b.add { { '  ' .. hidden .. ' resolved hidden', 'AzurePRMuted' } }
    end
  end

  for _, t in ipairs(visible) do
    local open = is_open(t)
    local t_hl = open and 'AzurePRThreadActive' or 'AzurePRThreadResolved'
    local is_folded = t.id ~= nil and folded[t.id] and true or false
    local loc, is_file = thread_location(t)
    local n_comments = #(t.comments or {})
    local thread_item = { kind = 'thread', pr = pr, thread = t, folded = is_folded }
    b.blank()
    local segs = {
      { (is_folded and icons.collapsed or icons.expanded) .. ' ', 'AzurePRGroup' },
      { (open and icons.thread_active or icons.thread_resolved) .. ' ', t_hl },
      { '[' .. oneline(t.status or 'active') .. ']', t_hl },
      { ' ' },
    }
    if is_file then
      segs[#segs + 1] = { (icons.file or '#') .. ' ', 'AzurePRFile' }
      segs[#segs + 1] = { oneline(loc), 'AzurePRFile' }
    else
      segs[#segs + 1] = { loc, 'AzurePRMuted' }
    end
    if is_folded then
      segs[#segs + 1] = { '  (' .. n_comments .. (n_comments == 1 and ' comment' or ' comments') .. ')', 'AzurePRMuted' }
    end
    b.add(segs, thread_item)

    if not is_folded then
      for _, entry in ipairs(comment_tree(t.comments)) do
        local c, depth = entry[1], entry[2]
        local indent = string.rep(' ', 4 + depth * 2)
        local citem = { kind = 'comment', pr = pr, thread = t, comment = c, depth = depth }
        local author = oneline(c.author and (c.author.name or c.author.unique_name) or '?')
        local when = relative_time(c.published_at, now)
        local hsegs = {
          { indent },
          { (icons.comment or '>') .. ' ', 'AzurePRMuted' },
          { author, c.type == 'system' and 'AzurePRMuted' or 'AzurePRCommentAuthor' },
        }
        if when ~= '' then
          hsegs[#hsegs + 1] = { dot .. when, 'AzurePRCommentDate' }
        end
        if c.updated_at and c.published_at and c.updated_at > c.published_at + 1 then
          hsegs[#hsegs + 1] = { ' (edited)', 'AzurePRCommentDate' }
        end
        if opts.user_id and c.author and c.author.id == opts.user_id then
          hsegs[#hsegs + 1] = { ' (you)', 'AzurePRMuted' }
        end
        b.add(hsegs, citem)
        local body_indent = indent .. '  '
        if c.is_deleted then
          b.add({ { body_indent }, { '(deleted)', 'AzurePRMuted' } }, citem)
        else
          local body = split(c.content)
          if #body == 0 then
            b.add({ { body_indent }, { '(empty)', 'AzurePRMuted' } }, citem)
          end
          for _, l in ipairs(body) do
            if l == '' then
              b.add('', citem)
            elseif c.type == 'system' then
              b.add({ { body_indent }, { l, 'AzurePRMuted' } }, citem)
            else
              b.add(body_indent .. l, citem)
            end
          end
        end
      end
    end
  end

  return b.result()
end

-- exported for tests / reuse
M._truncate = truncate
M._relative_time = relative_time
M._comment_tree = comment_tree

return M
