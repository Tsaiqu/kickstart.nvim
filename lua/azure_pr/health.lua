-- :checkhealth azure_pr
-- Only local checks are performed; no request is sent to Azure DevOps.
local M = {}

local h = vim.health

local function run(argv)
  local ok, res = pcall(function()
    return vim.system(argv, { text = true, cwd = vim.fn.getcwd(), env = { GIT_TERMINAL_PROMPT = '0' } }):wait(5000)
  end)
  if not ok then
    return nil, tostring(res)
  end
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr or '') ~= '' and vim.trim(res.stderr) or ('exit code ' .. tostring(res.code))
  end
  return vim.trim(res.stdout or '')
end

local function first_line(s)
  return (s or ''):match '^[^\n]*'
end

function M.check()
  h.start 'azure_pr: environment'
  if vim.fn.has 'nvim-0.10' == 1 then
    h.ok('Neovim ' .. tostring(vim.version()))
  else
    h.error('Neovim >= 0.10 is required (found ' .. tostring(vim.version()) .. ')')
  end

  if vim.fn.executable 'curl' == 1 then
    local out = run { 'curl', '--version' }
    h.ok('curl found: ' .. first_line(out or 'curl'))
  else
    h.error('curl not found in $PATH', { 'Install curl; every Azure DevOps request goes through it.' })
  end

  local has_git = vim.fn.executable 'git' == 1
  if has_git then
    h.ok 'git found'
  else
    h.warn('git not found in $PATH', {
      'git is used to detect organization/project from the remote, for the current-branch PR, line comments and checkout.',
      'Set `organization` and `project` in setup() if git is unavailable.',
    })
  end

  h.start 'azure_pr: configuration'
  local ok_cfg, config = pcall(require, 'azure_pr.config')
  if not ok_cfg then
    h.error('Cannot load azure_pr.config: ' .. tostring(config))
    return
  end
  if vim.fn.exists ':AzurePR' == 2 then
    h.ok 'setup() was called (:AzurePR exists)'
  else
    h.warn('The :AzurePR command does not exist', { "Call require('azure_pr').setup({}) in your config." })
  end
  local cfg = config.get()

  local pat, err = config.get_pat()
  if pat then
    local source
    if cfg.pat and vim.trim(cfg.pat) ~= '' then
      source = '`pat` option (consider using `pat_env` or `pat_cmd` instead)'
    elseif cfg.pat_cmd then
      source = '`pat_cmd`'
    elseif cfg.pat_env and vim.env[cfg.pat_env] and vim.trim(vim.env[cfg.pat_env]) ~= '' then
      source = '$' .. cfg.pat_env
    else
      source = '$AZURE_DEVOPS_EXT_PAT'
    end
    h.ok('Personal Access Token found (from ' .. source .. ', ' .. #pat .. ' chars)')
  else
    h.error(err or 'No Personal Access Token found', {
      'Create a PAT in Azure DevOps: User settings > Personal access tokens, scope "Code (Read & Write)".',
      'export AZURE_DEVOPS_PAT=... in your shell, or set `pat_cmd`, e.g. { "pass", "show", "azure/pat" }.',
    })
  end

  if cfg.organization and cfg.project then
    h.ok(('Target from config: organization=%s project=%s base_url=%s'):format(cfg.organization, cfg.project, cfg.base_url or 'https://dev.azure.com'))
  elseif has_git then
    local url, gerr = run { 'git', 'remote', 'get-url', 'origin' }
    if not url or url == '' then
      h.warn('organization/project not configured and no git remote "origin" in ' .. vim.fn.getcwd() .. (gerr and (' (' .. first_line(gerr) .. ')') or ''), {
        'Set `organization` and `project` in setup(), or run Neovim inside a clone of an Azure DevOps repository.',
      })
    else
      local remote = require('azure_pr.util').parse_remote(url)
      if remote then
        h.ok(
          ('Target from git remote: organization=%s project=%s repository=%s'):format(
            cfg.organization or remote.organization,
            cfg.project or remote.project,
            tostring(remote.repository)
          )
        )
      else
        h.warn('git remote "' .. config.redact_url(url) .. '" is not an Azure DevOps remote', { 'Set `organization` and `project` in setup().' })
      end
    end
  else
    h.warn 'organization/project not configured and git is unavailable to detect them'
  end

  if cfg.repositories and #cfg.repositories > 0 then
    h.info('Restricted to repositories: ' .. table.concat(cfg.repositories, ', '))
  else
    h.info 'All repositories of the project are listed (set `repositories` to restrict)'
  end
  h.info(cfg.icons and 'Nerd-font icons enabled (set `icons = false` for ASCII)' or 'ASCII icons')
  h.info 'No live request is made here; run :AzurePR list to test the connection.'
end

return M
