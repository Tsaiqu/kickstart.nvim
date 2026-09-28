---@diagnostic disable: duplicate-set-field, need-check-nil, param-type-mismatch, assign-type-mismatch, redundant-parameter, cast-local-type, missing-parameter
local config = require 'azure_pr.config'

local saved_env = {}
local function set_env(name, value)
  if saved_env[name] == nil then
    saved_env[name] = { vim.env[name] }
  end
  vim.env[name] = value
end
local function restore_env()
  for name, v in pairs(saved_env) do
    vim.env[name] = v[1]
  end
  saved_env = {}
end

describe('config.setup/get', function()
  it('returns defaults', function()
    config.setup()
    eq('https://dev.azure.com', config.get().base_url)
    eq('active', config.get().default_status)
    eq('<CR>', config.get().keymaps.list.open)
  end)
  it('deep merges and replaces lists', function()
    config.setup { organization = 'o', keymaps = { list = { refresh = 'U' } }, repositories = { 'a' } }
    eq('o', config.get().organization)
    eq('U', config.get().keymaps.list.refresh)
    eq('<CR>', config.get().keymaps.list.open)
    eq({ 'a' }, config.get().repositories)
    config.setup { repositories = { 'b' } }
    eq({ 'b' }, config.get().repositories)
    eq(nil, config.get().organization)
  end)
  it('does not mutate defaults', function()
    config.setup { keymaps = { list = { refresh = 'U' } } }
    eq('R', config.defaults.keymaps.list.refresh)
  end)
end)

describe('config.get_pat', function()
  local orig_run = config._run_pat_cmd
  local function reset()
    config._run_pat_cmd = orig_run
    restore_env()
    set_env('AZURE_DEVOPS_PAT', nil)
    set_env('AZURE_DEVOPS_EXT_PAT', nil)
    set_env('MY_PAT', nil)
  end

  it('prefers opts.pat', function()
    reset()
    set_env('AZURE_DEVOPS_PAT', 'envpat')
    local called = false
    config._run_pat_cmd = function()
      called = true
      return 'cmdpat'
    end
    config.setup { pat = 'optpat', pat_cmd = { 'x' } }
    eq('optpat', config.get_pat())
    falsy(called)
    reset()
  end)

  it('uses pat_cmd before env (trimmed)', function()
    reset()
    set_env('AZURE_DEVOPS_PAT', 'envpat')
    local got_cmd
    config._run_pat_cmd = function(cmd)
      got_cmd = cmd
      return '  cmdpat\n'
    end
    config.setup { pat_cmd = { 'pass', 'show', 'x' } }
    eq('cmdpat', config.get_pat())
    eq({ 'pass', 'show', 'x' }, got_cmd)
    reset()
  end)

  it('uses only the first non-empty line of pat_cmd output (pass entries)', function()
    reset()
    config._run_pat_cmd = function()
      return '\n  secret-token  \r\nuser: me@example.com\nurl: dev.azure.com\n'
    end
    config.setup { pat_cmd = { 'pass', 'show', 'azure/pat' } }
    eq('secret-token', config.get_pat())
    reset()
  end)

  it('runs a real pat_cmd', function()
    reset()
    config.setup { pat_cmd = { 'printf', 'realpat\n' } }
    eq('realpat', config.get_pat())
    config.setup { pat_cmd = 'echo shellpat' }
    eq('shellpat', config.get_pat())
    reset()
  end)

  it('falls back to env when pat_cmd fails', function()
    reset()
    set_env('AZURE_DEVOPS_PAT', 'envpat')
    config._run_pat_cmd = function()
      return nil, 'boom'
    end
    config.setup { pat_cmd = { 'x' } }
    eq('envpat', config.get_pat())
    reset()
  end)

  it('uses custom pat_env then AZURE_DEVOPS_EXT_PAT', function()
    reset()
    set_env('MY_PAT', 'mine')
    set_env('AZURE_DEVOPS_EXT_PAT', 'ext')
    config.setup { pat_env = 'MY_PAT' }
    eq('mine', config.get_pat())
    set_env('MY_PAT', nil)
    config.setup { pat_env = 'MY_PAT' }
    eq('ext', config.get_pat())
    reset()
  end)

  it('returns an error when nothing is configured', function()
    reset()
    config._run_pat_cmd = function()
      return nil, 'exit 1'
    end
    config.setup { pat_cmd = { 'x' } }
    local pat, err = config.get_pat()
    eq(nil, pat)
    contains(err, 'No Azure DevOps PAT')
    contains(err, 'exit 1')
    reset()
  end)

  it('caches the PAT until setup/clear_cache', function()
    reset()
    set_env('AZURE_DEVOPS_PAT', 'first')
    config.setup {}
    eq('first', config.get_pat())
    set_env('AZURE_DEVOPS_PAT', 'second')
    eq('first', config.get_pat())
    config.clear_cache()
    eq('second', config.get_pat())
    reset()
  end)
end)

describe('config.resolve_target', function()
  local orig_git = config._git_remote
  local function resolve()
    local done, err, target = false, nil, nil
    config.resolve_target(function(e, t)
      done, err, target = true, e, t
    end)
    truthy(
      wait_for(function()
        return done
      end, 1000),
      'resolve_target callback not called'
    )
    return err, target
  end

  it('uses config without calling git', function()
    local calls = 0
    config._git_remote = function(cb)
      calls = calls + 1
      cb 'https://dev.azure.com/x/y/_git/z'
    end
    config.setup { organization = 'org', project = 'Proj', repositories = { 'r1' }, base_url = 'https://tfs.local/' }
    local err, t = resolve()
    eq(nil, err)
    eq({ organization = 'org', project = 'Proj', repositories = { 'r1' }, base_url = 'https://tfs.local' }, t)
    eq(0, calls)
    config._git_remote = orig_git
  end)

  it('detects from git remote and caches', function()
    local calls = 0
    config._git_remote = function(cb)
      calls = calls + 1
      vim.schedule(function()
        cb 'https://myorg.visualstudio.com/Proj%20X/_git/repo'
      end)
    end
    config.setup {}
    local err, t = resolve()
    eq(nil, err)
    eq({ organization = 'myorg', project = 'Proj X', repositories = nil, base_url = 'https://myorg.visualstudio.com', repository = 'repo' }, t)
    resolve()
    eq(1, calls)
    config.clear_cache()
    resolve()
    eq(2, calls)
    config._git_remote = orig_git
  end)

  it('config values override detected ones', function()
    config._git_remote = function(cb)
      cb 'git@ssh.dev.azure.com:v3/myorg/proj/repo'
    end
    config.setup { project = 'Other' }
    local err, t = resolve()
    eq(nil, err)
    eq('myorg', t.organization)
    eq('Other', t.project)
    eq('https://dev.azure.com', t.base_url)
    config._git_remote = orig_git
  end)

  it('errors on non-azure remote', function()
    config._git_remote = function(cb)
      cb 'git@github.com:a/b.git'
    end
    config.setup {}
    local err, t = resolve()
    eq(nil, t)
    contains(err, 'not an Azure DevOps remote')
    config._git_remote = orig_git
  end)

  it('errors when git fails', function()
    config._git_remote = function(cb)
      cb(nil, 'fatal: not a git repository')
    end
    config.setup {}
    local err, t = resolve()
    eq(nil, t)
    contains(err, 'not a git repository')
    config._git_remote = orig_git
  end)

  it('real git seam returns a result in a non-repo dir', function()
    local cwd = vim.fn.getcwd()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    vim.cmd.cd(dir)
    local done, url, e = false, nil, nil
    config._git_remote(function(u, er)
      done, url, e = true, u, er
    end)
    truthy(wait_for(function()
      return done
    end, 3000))
    vim.cmd.cd(cwd)
    vim.fn.delete(dir, 'rf')
    eq(nil, url)
    truthy(e)
  end)
end)

config.setup {}

describe('config (review fixes)', function()
  it('pat_cmd has a timeout', function()
    config.setup { pat_cmd = { 'sh', '-c', 'sleep 5' }, pat_cmd_timeout = 200 }
    local t = vim.uv.hrtime()
    local out, err = config._run_pat_cmd { 'sh', '-c', 'sleep 5' }
    eq(nil, out)
    contains(err, 'timed out')
    truthy((vim.uv.hrtime() - t) / 1e6 < 3000, 'did not wait for the command')
    config.setup {}
  end)

  it('pat_cmd timeout with a lingering child returns an error in one timeout', function()
    config.setup { pat_cmd_timeout = 300 }
    local t = vim.uv.hrtime()
    local ok, out, err = pcall(config._run_pat_cmd, { 'sh', '-c', 'sleep 5; echo x' })
    truthy(ok, 'did not throw: ' .. tostring(out))
    eq(nil, out)
    contains(err, 'timed out')
    truthy((vim.uv.hrtime() - t) / 1e6 < 900, 'waited only one timeout')
    config.setup {}
  end)

  it('pat_cmd output and exit code', function()
    eq('tok\n', (config._run_pat_cmd { 'sh', '-c', 'echo tok' }))
    local out, err = config._run_pat_cmd { 'sh', '-c', 'echo bad >&2; exit 3' }
    eq(nil, out)
    contains(err, 'code 3')
  end)

  it('a failed pat_cmd runs once for a burst of requests', function()
    local orig = config._run_pat_cmd
    local saved = { vim.env.AZURE_DEVOPS_PAT, vim.env.AZURE_DEVOPS_EXT_PAT }
    vim.env.AZURE_DEVOPS_PAT, vim.env.AZURE_DEVOPS_EXT_PAT = nil, nil
    local n = 0
    config._run_pat_cmd = function()
      n = n + 1
      return nil, 'boom'
    end
    config.setup { pat_cmd = { 'x' } }
    for _ = 1, 4 do
      local pat, err = config.get_pat()
      eq(nil, pat)
      contains(err, 'boom')
    end
    eq(1, n)
    config.clear_cache()
    config.get_pat()
    eq(2, n, 'clear_cache retries')
    config._run_pat_cmd = orig
    vim.env.AZURE_DEVOPS_PAT, vim.env.AZURE_DEVOPS_EXT_PAT = saved[1], saved[2]
    config.setup {}
  end)

  it('redact_url strips credentials', function()
    eq('https://github.com/a/b', config.redact_url 'https://user:ghp_TOKEN@github.com/a/b')
    eq('git@github.com:a/b', config.redact_url 'git@github.com:a/b')
    eq('https://dev.azure.com/o/p/_git/r', config.redact_url 'https://dev.azure.com/o/p/_git/r')
  end)
end)
