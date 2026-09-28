---@diagnostic disable: duplicate-set-field, need-check-nil, param-type-mismatch, assign-type-mismatch, redundant-parameter, cast-local-type, missing-parameter
local PAT = 'super-secret-pat-123'

local function stub_config(overrides)
  local cfg = vim.tbl_extend('force', { api_version = '7.1', timeout = 17 }, overrides or {})
  package.loaded['azure_pr.config'] = {
    get = function()
      return cfg
    end,
    get_pat = function()
      if cfg.no_pat then
        return nil, 'nothing found'
      end
      return PAT
    end,
  }
end

local function load()
  reset_modules()
  stub_config()
  return require 'azure_pr.http'
end

--- Run http.request with a fake transport; returns call info and callback results.
local function run(http, opts, response)
  local call = {}
  http._transport = function(args, stdin, on_exit)
    call.args, call.stdin = args, stdin
    for i, a in ipairs(args) do
      if a == '--data-binary' then
        local path = args[i + 1]:sub(2)
        call.body_file = path
        local f = io.open(path, 'rb')
        call.body = f and f:read '*a'
        if f then
          f:close()
        end
      end
    end
    -- simulate a libuv callback (fast context)
    vim.uv.new_timer():start(0, 0, function()
      on_exit(response)
    end)
  end
  local res = {}
  http.request(opts, function(err, data, status)
    res.done = true
    res.err, res.data, res.status = err, data, status
    res.in_fast = vim.in_fast_event()
  end)
  res.sync = res.done == true
  truthy(
    wait_for(function()
      return res.done
    end, 2000),
    'callback not invoked'
  )
  return call, res
end

describe('http', function()
  it('url_encode keeps unreserved chars', function()
    local http = load()
    eq('a-b_c.d~e%20f%2Fg%3F', http.url_encode 'a-b_c.d~e f/g?')
  end)

  it('encodes query keys and always appends api-version', function()
    local http = load()
    local url = http.build_url({
      url = 'https://dev.azure.com/org/p/_apis/git/pullrequests',
      query = { ['searchCriteria.status'] = 'active', ['$top'] = 100, ['$skip'] = 0, ['searchCriteria.sourceRefName'] = 'refs/heads/feat x' },
    }, '7.1')
    eq(
      'https://dev.azure.com/org/p/_apis/git/pullrequests?$skip=0&$top=100&api-version=7.1&searchCriteria.sourceRefName=refs%2Fheads%2Ffeat%20x&searchCriteria.status=active',
      url
    )
  end)

  it('api_version override and existing ? in url', function()
    local http = load()
    eq('https://x/y?a=1&api-version=7.1-preview.1', http.build_url({ url = 'https://x/y?a=1', api_version = '7.1-preview.1' }, '7.1'))
    eq('https://x/y?api-version=5.0', http.build_url({ url = 'https://x/y', query = { ['api-version'] = '5.0' } }, '7.1'))
  end)

  it('build_curl_args GET has no body flags and reads config from stdin', function()
    local http = load()
    local args = http.build_curl_args({ method = 'GET', url = 'https://x/y', timeout = 5 }, nil)
    eq('curl', args[1])
    contains(args, '-sS')
    contains(args, '5')
    contains(args, 'GET')
    contains(args, 'Accept: application/json')
    falsy(vim.tbl_contains(args, '--data-binary'))
    falsy(vim.tbl_contains(args, 'Content-Type: application/json'))
    contains(args, '-K')
    contains(args, '-')
    contains(args, '\n%{http_code}')
    eq('https://x/y?api-version=7.1', args[#args])
  end)

  it('build_curl_args with body file', function()
    local http = load()
    local args = http.build_curl_args({ method = 'post', url = 'https://x/y' }, '/tmp/body.json')
    contains(args, 'POST')
    contains(args, 'Content-Type: application/json')
    contains(args, '@/tmp/body.json')
  end)

  it('auth config is basic auth of :PAT', function()
    local http = load()
    local cfg = http.build_auth_config(PAT)
    eq('header = "Authorization: Basic ' .. vim.base64.encode(':' .. PAT) .. '"\n', cfg)
  end)

  it('PAT never appears in argv; it goes through stdin', function()
    local http = load()
    local call, res = run(http, { method = 'POST', url = 'https://x/y', body = { content = 'hi' } }, { code = 0, stdout = '{"id":1}\n200' })
    local b64 = vim.base64.encode(':' .. PAT)
    for _, a in ipairs(call.args) do
      falsy(a:find(PAT, 1, true), 'PAT in argv')
      falsy(a:find(b64, 1, true), 'encoded PAT in argv')
    end
    contains(call.stdin, b64)
    eq(nil, res.err)
    eq({ id = 1 }, res.data)
    eq(200, res.status)
    eq('{"content":"hi"}', call.body)
    eq('-q', call.args[2], '-q must be the first curl option (ignore ~/.curlrc)')
    eq(17 .. '', call.args[5], 'timeout from config')
    wait_for(function()
      return vim.fn.filereadable(call.body_file) == 0
    end, 500)
    eq(0, vim.fn.filereadable(call.body_file), 'temp body file removed')
  end)

  it('callback is always scheduled on the main loop', function()
    local http = load()
    local _, res = run(http, { url = 'https://x/y' }, { code = 0, stdout = '{"value":[]}\n200' })
    falsy(res.sync, 'callback ran synchronously')
    falsy(res.in_fast, 'callback ran in fast event')
    -- errors before transport are scheduled too
    stub_config { no_pat = true }
    local err
    http.request({ url = 'https://x' }, function(e)
      err = e
    end)
    eq(nil, err, 'error callback ran synchronously')
    wait_for(function()
      return err ~= nil
    end)
    contains(err, 'No Azure DevOps PAT')
  end)

  it('supports DELETE with empty body', function()
    local http = load()
    local call, res = run(http, { method = 'DELETE', url = 'https://x/c/1' }, { code = 0, stdout = '\n200' })
    contains(call.args, 'DELETE')
    eq(nil, res.err)
    eq(nil, res.data)
    eq(200, res.status)
  end)

  it('rejects unknown methods', function()
    local http = load()
    local err
    http.request({ method = 'FOO', url = 'https://x' }, function(e)
      err = e
    end)
    wait_for(function()
      return err
    end)
    contains(err, 'Unsupported')
  end)

  it('204 no content is ok', function()
    local http = load()
    local _, res = run(http, { url = 'https://x' }, { code = 0, stdout = '\n204' })
    eq(nil, res.err)
    eq(204, res.status)
  end)

  it('maps curl failure', function()
    local http = load()
    local _, res = run(http, { url = 'https://x' }, { code = 6, stdout = '', stderr = 'Could not resolve host' })
    contains(res.err, 'curl failed')
    contains(res.err, 'Could not resolve host')
  end)

  it('redacts an Authorization header traced to stderr', function()
    local http = load()
    local _, res = run(
      http,
      { url = 'https://x' },
      { code = 28, stdout = '', stderr = '> GET / HTTP/2\n> Authorization: Basic OnNlY3JldA==\ncurl: (28) timeout' }
    )
    contains(res.err, 'curl failed')
    falsy(res.err:find('OnNlY3JldA', 1, true), 'token leaked')
    contains(res.err, 'Authorization: <redacted>')
  end)

  it('maps HTTP errors with Azure message', function()
    local http = load()
    local _, res = run(http, { url = 'https://x' }, { code = 0, stdout = '{"message":"TF401180: The requested pull request was not found."}\n404' })
    contains(res.err, 'HTTP 404')
    contains(res.err, 'TF401180')
    eq(404, res.status)
  end)

  it('401 includes PAT hint', function()
    local http = load()
    local _, res = run(http, { url = 'https://x' }, { code = 0, stdout = '<html>nope</html>\n401' })
    contains(res.err, 'HTTP 401')
    contains(res.err, 'PAT')
  end)

  it('203 with HTML is an auth error', function()
    local http = load()
    local _, res = run(http, { url = 'https://x' }, { code = 0, stdout = '<!DOCTYPE html><html>Sign in</html>\n203' })
    contains(res.err, 'Authentication failed')
  end)

  it('JSON decode failure on 200', function()
    local http = load()
    local _, res = run(http, { url = 'https://x' }, { code = 0, stdout = '{not json\n200' })
    contains(res.err, 'decode')
  end)

  it('decodes null as nil (luanil)', function()
    local http = load()
    local _, res = run(http, { url = 'https://x' }, { code = 0, stdout = '{"a":null,"b":[1]}\n200' })
    eq({ b = { 1 } }, res.data)
  end)

  it('body containing newlines parses status from last line', function()
    local http = load()
    local body, status = http.parse_output '{\n "a": 1\n}\n201'
    eq('{\n "a": 1\n}', body)
    eq(201, status)
  end)

  it('root_url', function()
    local http = load()
    eq('https://dev.azure.com/my%20org', http.root_url { organization = 'my org', base_url = 'https://dev.azure.com/' })
    eq('https://dev.azure.com/org', http.root_url { organization = 'org' })
    eq('https://org.visualstudio.com', http.root_url { organization = 'org', base_url = 'https://org.visualstudio.com' })
    eq('https://tfs.local/tfs/Coll', http.root_url { organization = 'Coll', base_url = 'https://tfs.local/tfs' })
  end)

  it('default transport handles missing binary gracefully', function()
    local http = load()
    local got
    http._transport({ 'definitely-not-a-binary-xyz' }, nil, function(res)
      got = res
    end)
    wait_for(function()
      return got
    end)
    truthy(got and got.code ~= 0)
  end)
end)
