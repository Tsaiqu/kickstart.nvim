-- Configuration, PAT lookup and target (organization/project) resolution for azure_pr.
local util = require 'azure_pr.util'

local M = {}

M.defaults = {
  organization = nil, -- 'myorg'; auto-detected from git remote if nil
  project = nil, -- 'MyProject'; auto-detected from git remote if nil
  repositories = nil, -- nil = all repos in project; or list of repo names
  base_url = 'https://dev.azure.com', -- override for on-prem / visualstudio.com
  pat = nil, -- string PAT (discouraged)
  pat_env = 'AZURE_DEVOPS_PAT', -- env var to read PAT from (AZURE_DEVOPS_EXT_PAT is tried as well)
  pat_cmd = nil, -- e.g. { 'pass', 'show', 'azure/pat' }; first non-empty stdout line is the PAT (a string runs via `sh -c`)
  api_version = '7.1',
  timeout = 30, -- seconds for curl --max-time
  pat_cmd_timeout = 10000, -- ms before pat_cmd is killed (it runs synchronously)
  default_status = 'active', -- active|completed|abandoned|all
  max_prs = 200,
  default_group_by = 'repository', -- none|repository|author|review_state|target_branch|my_vote
  default_filters = {},
  date_format = '%Y-%m-%d %H:%M',
  icons = true, -- nerd-font icons; false => ascii
  list = { layout = 'tab' }, -- 'tab' | 'split' | 'vsplit' | 'current'
  -- Each keymap value is a lhs string, a list of lhs strings, or false to disable.
  keymaps = {
    global = {
      enabled = true,
      group_prefix = '<leader>p', -- labelled 'Azure [P]R' in which-key (if installed)
      list = '<leader>pl',
      mine = '<leader>pm',
      review = '<leader>pr',
      current = '<leader>pc',
      comment = '<leader>pa', -- normal & visual mode
    },
    list = {
      open = '<CR>',
      toggle_group = 'za', -- add '<Tab>' yourself if it is not mapped globally (e.g. bufferline)
      refresh = 'R',
      text_filter = { '/', 'f' },
      filter_menu = 'F',
      clear_filters = 'X',
      group_by = 'gb', -- not 'g': it would shadow gg
      status = 's',
      toggle_mine = 'm',
      toggle_needs_vote = 'r',
      browser = 'o',
      yank_url = 'y',
      comment = 'c',
      vote = 'v',
      checkout = 'C',
      help = '?',
      close = 'q',
    },
    detail = {
      comment = 'c',
      reply = 'r',
      edit = 'e',
      delete = 'd',
      thread_status = 's',
      toggle_resolved = 't',
      toggle_thread = 'za',
      open_file = '<CR>',
      -- not 'v' / 'y' / 'gv': the detail buffer is read-only text, keep visual mode, reselect
      -- and the yank operator; 'A' (approve menu) has no meaning in a non-modifiable buffer
      vote = 'A',
      browser = 'o',
      yank_url = 'gy',
      refresh = 'R',
      close = 'q',
      help = '?',
      prev_thread = '[t',
      next_thread = ']t',
    },
  },
}

local options = vim.deepcopy(M.defaults)
local user_opts = {}
local pat_cache = nil
local pat_error = nil -- { msg, at } remembered failed pat_cmd lookup (see get_pat)
local PAT_ERROR_TTL = 5000 -- ms; long enough to cover the parallel requests of one fetch
local target_cache = nil

---Merge user options over the defaults. Clears PAT and target caches.
---@param opts table|nil
function M.setup(opts)
  user_opts = opts or {}
  options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), user_opts)
  -- Lists should be replaced, not merged index-wise.
  if user_opts.repositories ~= nil then
    options.repositories = vim.deepcopy(user_opts.repositories)
  end
  if user_opts.pat_cmd ~= nil then
    options.pat_cmd = vim.deepcopy(user_opts.pat_cmd)
  end
  M.clear_cache()
end

---@return table merged configuration
function M.get()
  return options
end

---Drop the cached PAT and resolved target.
function M.clear_cache()
  pat_cache = nil
  pat_error = nil
  target_cache = nil
end

local function nonempty(s)
  if type(s) ~= 'string' then
    return nil
  end
  s = vim.trim(s)
  return s ~= '' and s or nil
end

---Test seam: run the PAT command, returns stdout (or nil, err).
---@param cmd string|string[]
---@return string|nil, string|nil
function M._run_pat_cmd(cmd)
  local argv = type(cmd) == 'string' and { 'sh', '-c', cmd } or cmd
  local timeout = tonumber(options.pat_cmd_timeout) or 10000
  local res
  -- detach: the command becomes a process group leader, so on timeout the whole group
  -- (e.g. `pass` -> gpg -> pinentry) can be killed. SystemObj:wait() is not used because it
  -- waits a second `timeout` after killing and returns nil while a grandchild keeps the
  -- stdout pipe open; we poll for the result ourselves instead (one timeout, never nil-indexed).
  local ok, obj = pcall(vim.system, argv, { text = true, detach = true }, function(r)
    res = r
  end)
  if not ok then
    return nil, 'pat_cmd failed to start: ' .. tostring(obj)
  end
  vim.wait(timeout, function()
    return res ~= nil
  end, 10)
  if not res then
    local uv = vim.uv or vim.loop
    if obj.pid then
      pcall(uv.kill, -obj.pid, 'sigkill')
    end
    pcall(obj.kill, obj, 9)
    return nil, 'pat_cmd timed out after ' .. timeout .. ' ms'
  end
  if res.signal == 15 or res.signal == 9 or res.code == 124 then
    return nil, 'pat_cmd timed out after ' .. timeout .. ' ms'
  end
  if res.code ~= 0 then
    return nil, 'pat_cmd exited with code ' .. res.code .. (nonempty(res.stderr) and (': ' .. vim.trim(res.stderr)) or '')
  end
  return res.stdout
end

---Get the Personal Access Token.
---Order: opts.pat, pat_cmd, env[pat_env], env AZURE_DEVOPS_EXT_PAT. Successful lookups are cached.
---@return string|nil pat, string|nil err
function M.get_pat()
  if pat_cache then
    return pat_cache
  end
  if pat_error and (vim.uv or vim.loop).now() - pat_error.at < PAT_ERROR_TTL then
    return nil, pat_error.msg
  end
  pat_error = nil
  local pat = nonempty(options.pat)
  local cmd_err
  if not pat and options.pat_cmd then
    local out, err = M._run_pat_cmd(options.pat_cmd)
    -- only the first non-empty line: `pass show` prints metadata (user:, url:) after the secret
    pat = nonempty(type(out) == 'string' and out:match '^%s*([^\r\n]+)' or nil)
    if not pat then
      cmd_err = err or 'pat_cmd returned empty output'
    end
  end
  if not pat and options.pat_env then
    pat = nonempty(vim.env[options.pat_env])
  end
  if not pat then
    pat = nonempty(vim.env.AZURE_DEVOPS_EXT_PAT)
  end
  if not pat then
    local msg = 'No Azure DevOps PAT configured: set $' .. (options.pat_env or 'AZURE_DEVOPS_PAT') .. ', $AZURE_DEVOPS_EXT_PAT, `pat_cmd` or `pat`'
    if cmd_err then
      msg = msg .. ' (' .. cmd_err .. ')'
    end
    -- remember a pat_cmd failure briefly: every HTTP request calls get_pat() and pat_cmd runs
    -- synchronously, so without this a slow/failing command would block the UI once per request.
    -- Short TTL (and clear_cache()/setup()) so a later user-triggered refresh retries.
    if cmd_err then
      pat_error = { msg = msg, at = (vim.uv or vim.loop).now() }
    end
    return nil, msg
  end
  pat_cache = pat
  return pat
end

---Remove credentials (userinfo) from a URL before showing it.
---@param url string
---@return string
function M.redact_url(url)
  return (tostring(url):gsub('^(%a[%w+.-]*://)[^@/]+@', '%1'))
end

---Test seam: asynchronously get the `origin` remote URL of the git repo in cwd.
---@param cb fun(url: string|nil, err: string|nil)
function M._git_remote(cb)
  local ok, err = pcall(vim.system, { 'git', 'remote', 'get-url', 'origin' }, {
    text = true,
    cwd = vim.fn.getcwd(),
    env = { GIT_TERMINAL_PROMPT = '0' },
    timeout = 10000,
  }, function(res)
    if res.code ~= 0 then
      cb(nil, vim.trim(res.stderr or '') ~= '' and vim.trim(res.stderr) or 'git remote get-url origin failed')
    else
      cb(vim.trim(res.stdout or ''))
    end
  end)
  if not ok then
    cb(nil, 'failed to run git: ' .. tostring(err))
  end
end

---@class AzurePRTarget
---@field organization string
---@field project string
---@field repositories string[]|nil
---@field base_url string
---@field repository string|nil repo detected from the git remote (informational only)

---Resolve organization/project. Uses config when both are set, otherwise the git remote of cwd
---(explicit config values win over detected ones). Cached after the first success.
---The callback runs synchronously when config/cache suffice, otherwise on the main loop (vim.schedule).
---@param cb fun(err: string|nil, target: AzurePRTarget|nil)
function M.resolve_target(cb)
  if target_cache then
    return cb(nil, target_cache)
  end
  local o = options
  if o.organization and o.project then
    target_cache = {
      organization = o.organization,
      project = o.project,
      repositories = o.repositories,
      base_url = (o.base_url or 'https://dev.azure.com'):gsub('/+$', ''),
    }
    return cb(nil, target_cache)
  end
  M._git_remote(function(url, err)
    vim.schedule(function()
      if not url then
        return cb('Cannot determine Azure DevOps organization/project: set `organization` and `project` in setup() (' .. tostring(err) .. ')')
      end
      local remote = util.parse_remote(url)
      if not remote then
        return cb('Git remote "' .. M.redact_url(url) .. '" is not an Azure DevOps remote; set `organization` and `project` in setup()')
      end
      local base_url = user_opts.base_url or remote.base_url
      target_cache = {
        organization = o.organization or remote.organization,
        project = o.project or remote.project,
        repositories = o.repositories,
        base_url = base_url:gsub('/+$', ''),
        repository = remote.repository,
      }
      cb(nil, target_cache)
    end)
  end)
end

return M
