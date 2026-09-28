-- Pure helper functions for azure_pr (no network, no buffer IO).
local M = {}

---Decode percent-encoded characters (`%20` -> space).
---@param s string
---@return string
function M.url_decode(s)
  return (s:gsub('%%(%x%x)', function(h)
    return string.char(tonumber(h, 16))
  end))
end

---Percent-encode a string for use as a URL path segment / query value.
---RFC3986 unreserved characters (A-Z a-z 0-9 - . _ ~) are kept as is.
---@param str string|number
---@return string
function M.url_encode(str)
  str = tostring(str)
  return (str:gsub('[^%w%-%._~]', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
end

---@class AzurePRRemote
---@field organization string
---@field project string
---@field repository string
---@field base_url string

local function split_path(path)
  local parts = {}
  for seg in path:gmatch '[^/]+' do
    table.insert(parts, M.url_decode(seg))
  end
  return parts
end

local function strip_git_suffix(s)
  s = s:gsub('/+$', '')
  s = s:gsub('%.git$', '')
  return s
end

---Build a remote from path segments of the form `[collection/]project/_git/repo`.
---When the project segment is missing (`/_git/repo`) Azure uses the repo name as project.
local function from_git_path(parts, organization, base_url)
  local idx
  for i, p in ipairs(parts) do
    if p == '_git' then
      idx = i
      break
    end
  end
  if not idx or not parts[idx + 1] then
    return nil
  end
  -- `_git/_optimized/repo` and `_git/_full/repo` are special clone URLs.
  local repo = parts[idx + 1]
  if (repo == '_optimized' or repo == '_full') and parts[idx + 2] then
    repo = parts[idx + 2]
  end
  local project = parts[idx - 1]
  if project and project:lower() == 'defaultcollection' then
    project = nil
  end
  project = project or repo
  return { organization = organization, project = project, repository = repo, base_url = base_url }
end

---Parse a git remote URL pointing at Azure DevOps.
---Supported forms:
---  https://[user@]dev.azure.com/org/project/_git/repo
---  git@ssh.dev.azure.com:v3/org/project/repo  (also ssh://git@ssh.dev.azure.com/v3/...)
---  https://org.visualstudio.com/[DefaultCollection/]project/_git/repo
---  org@vs-ssh.visualstudio.com:v3/org/project/repo  (also ssh://...)
---@param url string|nil
---@return AzurePRRemote|nil
function M.parse_remote(url)
  if type(url) ~= 'string' then
    return nil
  end
  url = vim.trim(url)
  if url == '' then
    return nil
  end
  url = strip_git_suffix(url)

  -- SSH forms: [ssh://]user@host[:/]v3/org/project/repo
  local host, rest = url:match '^ssh://[^@/]+@([^/:]+)[:/]?%d*/(v3/.+)$'
  if not host then
    host, rest = url:match '^[^@/:]+@([^/:]+):/?(v3/.+)$'
  end
  if host then
    local parts = split_path(rest)
    -- parts: v3, org, project, repo
    if #parts < 4 then
      return nil
    end
    local org, project, repo = parts[2], parts[3], parts[4]
    host = host:lower()
    if host == 'ssh.dev.azure.com' then
      return { organization = org, project = project, repository = repo, base_url = 'https://dev.azure.com' }
    elseif host == 'vs-ssh.visualstudio.com' then
      return { organization = org, project = project, repository = repo, base_url = 'https://' .. org .. '.visualstudio.com' }
    end
    return nil
  end

  -- HTTP(S) forms
  local scheme, authority, path = url:match '^(https?)://([^/]+)(/.*)$'
  if not scheme then
    return nil
  end
  local hostname = authority:gsub('^.*@', ''):gsub(':%d+$', ''):lower()
  local parts = split_path(path)

  if hostname == 'dev.azure.com' then
    local org = parts[1]
    if not org or org == '_git' then
      return nil
    end
    local rest_parts = vim.list_slice(parts, 2)
    return from_git_path(rest_parts, org, scheme .. '://dev.azure.com')
  end

  local org = hostname:match '^([^.]+)%.visualstudio%.com$'
  if org then
    return from_git_path(parts, org, scheme .. '://' .. org .. '.visualstudio.com')
  end
  return nil
end

-- Days since 1970-01-01 for a proleptic Gregorian civil date (H. Hinnant's algorithm).
local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

---Parse an ISO-8601 timestamp (as returned by Azure, e.g. `2024-01-02T03:04:05.1234567Z`) to a UTC epoch.
---Without a zone designator the time is treated as UTC. `+hh:mm`/`-hh:mm` offsets are honoured.
---Azure's "unset" date (`0001-01-01T00:00:00`) returns nil.
---@param iso string|nil
---@return integer|nil
function M.parse_date(iso)
  if type(iso) ~= 'string' then
    return nil
  end
  local y, mo, d, h, mi, s, rest = iso:match '^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):?(%d*)(.*)$'
  if not y then
    y, mo, d = iso:match '^(%d%d%d%d)%-(%d%d)%-(%d%d)$'
    if not y then
      return nil
    end
    h, mi, s, rest = '0', '0', '0', ''
  end
  y, mo, d, h, mi = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi)
  s = tonumber(s) or 0
  if y <= 1 then
    return nil
  end
  if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or s > 60 then
    return nil
  end
  local epoch = days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s
  rest = rest:gsub('^%.%d+', '')
  local sign, oh, om = rest:match '^([+-])(%d%d):?(%d%d)$'
  if sign then
    local off = tonumber(oh) * 3600 + tonumber(om) * 60
    epoch = sign == '+' and epoch - off or epoch + off
  end
  return epoch
end

---Human friendly relative time. Beyond 30 days uses months (`2mo ago`) and beyond 365 days years (`1y ago`).
---Future timestamps render as 'just now'.
---@param epoch integer|nil
---@param now integer|nil defaults to os.time()
---@return string
function M.relative_time(epoch, now)
  if not epoch then
    return ''
  end
  now = now or os.time()
  local diff = now - epoch
  if diff < 60 then
    return 'just now'
  elseif diff < 3600 then
    return math.floor(diff / 60) .. 'm ago'
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. 'h ago'
  elseif diff < 30 * 86400 then
    return math.floor(diff / 86400) .. 'd ago'
  elseif diff < 365 * 86400 then
    return math.floor(diff / (30 * 86400)) .. 'mo ago'
  end
  return math.floor(diff / (365 * 86400)) .. 'y ago'
end

---Format an epoch in local time.
---@param epoch integer|nil
---@param fmt string|nil defaults to '%Y-%m-%d %H:%M'
---@return string
function M.format_date(epoch, fmt)
  if not epoch then
    return ''
  end
  return os.date(fmt or '%Y-%m-%d %H:%M', epoch) --[[@as string]]
end

---`refs/heads/main` -> `main`.
---@param ref string|nil
---@return string|nil
function M.strip_ref(ref)
  if type(ref) ~= 'string' then
    return ref
  end
  return (ref:gsub('^refs/heads/', ''))
end

---Truncate to a display width, appending `…` when shortened. Multibyte/wide-character aware.
---@param str string|nil
---@param width integer
---@return string
function M.truncate(str, width)
  str = str or ''
  if width <= 0 then
    return ''
  end
  if vim.fn.strdisplaywidth(str) <= width then
    return str
  end
  local ellipsis = '…'
  local avail = width - 1
  local out = {}
  local used = 0
  local n = vim.fn.strchars(str)
  for i = 0, n - 1 do
    local ch = vim.fn.strcharpart(str, i, 1)
    local w = vim.fn.strdisplaywidth(ch)
    if used + w > avail then
      break
    end
    table.insert(out, ch)
    used = used + w
  end
  return table.concat(out) .. ellipsis
end

---Pad with spaces on the right to reach the given display width (never truncates).
---@param str string|nil
---@param width integer
---@return string
function M.pad_right(str, width)
  str = str or ''
  local w = vim.fn.strdisplaywidth(str)
  if w >= width then
    return str
  end
  return str .. string.rep(' ', width - w)
end

---Split a string into lines, normalising `\r\n` and `\r`.
---@param str string|nil
---@return string[]
function M.split_lines(str)
  if str == nil or str == '' then
    return {}
  end
  str = str:gsub('\r\n', '\n'):gsub('\r', '\n')
  return vim.split(str, '\n', { plain = true })
end

---@param msg string
---@param level integer|nil vim.log.levels.*
function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'Azure PR' })
end

return M
