-- Minimal async HTTP client for the Azure DevOps REST API, built on `curl` via `vim.system`.
--
-- Security: the PAT is NEVER placed in curl's argv (it would be visible in `ps`). The
-- `Authorization` header is passed through a curl config read from stdin (`-K -`), and the
-- request body (if any) is written to a temp file and sent with `--data-binary @file`.
local M = {}

local SEP = '\n' -- separator between body and the `-w` http_code trailer

--- Methods accepted by `M.request`.
M.METHODS = { GET = true, POST = true, PATCH = true, PUT = true, DELETE = true }

--- Test seam: transport(args, stdin, on_exit) where on_exit receives `{ code, stdout, stderr }`.
--- The default runs curl through `vim.system`. `on_exit` may be called from a luv callback (not
--- the main loop); `M.request` always re-schedules the user callback.
---@param args string[]
---@param stdin string|nil
---@param on_exit fun(res: { code: integer, stdout: string|nil, stderr: string|nil })
M._transport = function(args, stdin, on_exit)
  local ok, err = pcall(vim.system, args, { stdin = stdin, text = true }, function(res)
    on_exit { code = res.code, stdout = res.stdout, stderr = res.stderr }
  end)
  if not ok then
    on_exit { code = -1, stdout = '', stderr = tostring(err) }
  end
end

--- Percent-encode a string (RFC 3986: unreserved characters are kept).
---@param str any
---@return string
function M.url_encode(str)
  str = tostring(str)
  return (str:gsub('[^%w%-%._~]', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
end

-- Query keys are encoded like values except `$` which Azure expects literally (`$top`, `$skip`).
local function encode_key(key)
  return (M.url_encode(key):gsub('%%24', '$'))
end

--- Build a query string (without leading `?`) from a table. Keys are sorted for determinism.
--- Boolean values are rendered as `true`/`false`; nil values are skipped.
---@param query table<string, any>|nil
---@return string
function M.encode_query(query)
  if not query then
    return ''
  end
  local keys = vim.tbl_keys(query)
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = query[k]
    if v ~= nil and v ~= vim.NIL then
      table.insert(parts, encode_key(k) .. '=' .. M.url_encode(tostring(v)))
    end
  end
  return table.concat(parts, '&')
end

--- Build the final URL: `opts.url` + encoded `opts.query` + `api-version`.
--- `api-version` defaults to config `api_version` ('7.1') unless the query or `opts.api_version` sets it.
---@param opts { url: string, query: table|nil, api_version: string|nil }
---@param default_version string|nil
---@return string
function M.build_url(opts, default_version)
  local query = vim.deepcopy(opts.query or {})
  if query['api-version'] == nil then
    query['api-version'] = opts.api_version or default_version or '7.1'
  end
  local qs = M.encode_query(query)
  local sep = opts.url:find('?', 1, true) and '&' or '?'
  return opts.url .. sep .. qs
end

--- Contents of the curl config (fed via stdin with `-K -`) carrying the auth header.
---@param pat string
---@return string
function M.build_auth_config(pat)
  local token = vim.base64.encode(':' .. pat)
  return 'header = "Authorization: Basic ' .. token .. '"\n'
end

--- Build curl argv (pure, for unit tests). The PAT is never part of it.
--- Deviation from spec: the second parameter is the request body temp file (the auth header
--- always travels via the stdin curl config `-K -`, so no header file is needed).
---@param opts { method: string|nil, url: string, query: table|nil, api_version: string|nil, timeout: number|nil, default_api_version: string|nil }
---@param body_file string|nil path of the file holding the JSON body
---@return string[]
function M.build_curl_args(opts, body_file)
  local method = (opts.method or 'GET'):upper()
  local args = {
    'curl',
    '-q', -- must be argv[2]: ignore ~/.curlrc (verbose/trace there would leak the auth header, others break parsing)
    '-sS',
    '--max-time',
    tostring(opts.timeout or 30),
    '-X',
    method,
    '-H',
    'Accept: application/json',
  }
  if body_file then
    vim.list_extend(args, { '-H', 'Content-Type: application/json', '--data-binary', '@' .. body_file })
  end
  vim.list_extend(args, { '-w', SEP .. '%{http_code}', '-K', '-', M.build_url(opts, opts.default_api_version) })
  return args
end

--- Split curl stdout into body and http status (the `-w` trailer is the last line).
---@param stdout string|nil
---@return string body, integer|nil status
function M.parse_output(stdout)
  stdout = stdout or ''
  local body, code = stdout:match '^(.*)\n(%d%d%d)%s*$'
  if not body then
    code = stdout:match '^(%d%d%d)%s*$'
    body = ''
  end
  return body, tonumber(code)
end

local function decode(body)
  if not body or body:match '^%s*$' then
    return true, nil
  end
  local ok, data = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  return ok, data
end

local AUTH_HINT = 'check your Azure DevOps PAT (scopes: Code Read & Write, Project Read) and that it has not expired'

--- Map an HTTP response to (err, data).
---@param status integer|nil
---@param body string
---@return string|nil err, any data
function M.interpret(status, body)
  local ok, data = decode(body)
  if not status or status == 0 then
    return 'No HTTP response received', nil
  end
  if status == 203 and (not ok or type(data) ~= 'table') then
    return 'Authentication failed (HTTP 203, sign-in page returned): ' .. AUTH_HINT, nil
  end
  if status >= 400 then
    local msg = ok and type(data) == 'table' and data.message or nil
    if not msg and not ok then
      msg = vim.trim(body):sub(1, 200)
    end
    local err = 'HTTP ' .. status
    if msg and msg ~= '' then
      err = err .. ': ' .. msg
    end
    if status == 401 then
      err = err .. ' (' .. AUTH_HINT .. ')'
    elseif status == 403 then
      err = err .. ' (PAT lacks permissions for this operation)'
    end
    return err, ok and data or nil
  end
  if not ok then
    return 'Failed to decode JSON response (HTTP ' .. status .. '): ' .. tostring(data), nil
  end
  return nil, data
end

--- Perform an HTTP request against Azure DevOps.
--- `cb(err, data, status)` is always invoked on the main loop (via `vim.schedule`).
---@param opts { method: 'GET'|'POST'|'PATCH'|'PUT'|'DELETE'|nil, url: string, query: table|nil, body: table|nil, api_version: string|nil }
---@param cb fun(err: string|nil, data: any, status: integer|nil)
function M.request(opts, cb)
  local function done(err, data, status)
    vim.schedule(function()
      cb(err, data, status)
    end)
  end

  local method = (opts.method or 'GET'):upper()
  if not M.METHODS[method] then
    return done('Unsupported HTTP method: ' .. method)
  end

  local config = require 'azure_pr.config'
  local cfg = config.get() or {}
  local ok_pat, pat, pat_err = pcall(config.get_pat)
  if not ok_pat then
    pat, pat_err = nil, tostring(pat)
  end
  if not pat or pat == '' then
    return done('No Azure DevOps PAT configured (set $AZURE_DEVOPS_PAT, or `pat` / `pat_cmd` in setup())' .. (pat_err and (': ' .. pat_err) or ''))
  end

  local body_file
  if opts.body ~= nil then
    local ok_enc, encoded = pcall(vim.json.encode, opts.body)
    if not ok_enc then
      return done('Failed to encode request body: ' .. tostring(encoded))
    end
    body_file = vim.fn.tempname()
    local f = io.open(body_file, 'wb')
    if not f then
      return done('Failed to write request body to ' .. body_file)
    end
    f:write(encoded)
    f:close()
  end

  local args = M.build_curl_args({
    method = method,
    url = opts.url,
    query = opts.query,
    api_version = opts.api_version,
    default_api_version = cfg.api_version,
    timeout = cfg.timeout,
  }, body_file)

  M._transport(args, M.build_auth_config(pat), function(res)
    if body_file then
      os.remove(body_file)
    end
    if res.code ~= 0 then
      -- defense in depth: never echo an auth header that curl may have traced to stderr
      local stderr = vim.trim((res.stderr or ''):gsub('[Aa]uthorization:[^\r\n]*', 'Authorization: <redacted>'))
      return done(string.format('curl failed (exit %s)%s', tostring(res.code), stderr ~= '' and (': ' .. stderr) or ''))
    end
    local body, status = M.parse_output(res.stdout)
    local err, data = M.interpret(status, body)
    done(err, data, status)
  end)
end

--- API root for a target: `https://dev.azure.com/<org>` or, for `*.visualstudio.com`
--- (and other hosts whose base_url already identifies the collection), base_url as is.
---@param target { organization: string|nil, base_url: string|nil }
---@return string
function M.root_url(target)
  local base = (target.base_url or 'https://dev.azure.com'):gsub('/+$', '')
  if base:match '%.visualstudio%.com$' or not target.organization or target.organization == '' then
    return base
  end
  return base .. '/' .. M.url_encode(target.organization)
end

return M
