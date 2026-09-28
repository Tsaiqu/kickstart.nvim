-- End-to-end: real modules everywhere, only the curl transport (http._transport) is faked.
-- setup -> :AzurePR list -> grouped list -> filter -> <CR> detail -> threads -> reply (input float)
-- -> POST body -> thread status PATCH -> new general comment POST.
---@diagnostic disable: duplicate-set-field, need-check-nil, param-type-mismatch, assign-type-mismatch
local F = require 'azure_pr.tests.fixtures'

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

local ROOT = 'https://dev.azure.com/myorg'
local PROJECT_API = ROOT .. '/MyProject/_apis'

local function url_decode(s)
  return (s:gsub('%%(%x%x)', function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function parse_url(url)
  local path, qs = url:match '^([^?]*)%??(.*)$'
  local query = {}
  for pair in qs:gmatch '[^&]+' do
    local k, v = pair:match '^([^=]*)=(.*)$'
    if k then
      query[url_decode(k)] = url_decode(v)
    end
  end
  return path, query
end

--- Fake Azure DevOps server. State is mutated by POST/PATCH so refreshes see the changes.
local function fake_server()
  local srv = { requests = {}, prs = F.prs(), threads = F.threads(), next_thread = 100, next_comment = 50 }

  local function pr_by_id(id)
    for _, pr in ipairs(srv.prs) do
      if tostring(pr.pullRequestId) == tostring(id) then
        return pr
      end
    end
  end

  local function thread_by_id(id)
    for _, t in ipairs(srv.threads) do
      if tostring(t.id) == tostring(id) then
        return t
      end
    end
  end

  local me = vim.tbl_extend('force', vim.deepcopy(F.ME), {})

  --- returns status, body_table
  function srv.handle(method, path, query, body)
    if method == 'GET' and path == ROOT .. '/_apis/connectionData' then
      return 200,
        {
          authenticatedUser = {
            id = F.ME.id,
            providerDisplayName = F.ME.displayName,
            properties = { Account = { ['$type'] = 'System.String', ['$value'] = F.ME.uniqueName } },
          },
        }
    end
    if method == 'GET' and path == PROJECT_API .. '/git/pullrequests' then
      local status = query['searchCriteria.status']
      local out = {}
      for _, pr in ipairs(srv.prs) do
        if status == 'all' or pr.status == status then
          table.insert(out, pr)
        end
      end
      return 200, { value = out, count = #out }
    end
    if method == 'GET' and path == PROJECT_API .. '/policy/evaluations' then
      return 200,
        {
          value = {
            { status = 'approved', configuration = { isBlocking = true, type = { displayName = 'Minimum number of reviewers' } } },
          },
        }
    end
    local repo, id, rest = path:match('^' .. vim.pesc(PROJECT_API) .. '/git/repositories/([^/]+)/pullRequests/(%d+)(.*)$')
    if not repo then
      return 404, { message = 'No route for ' .. method .. ' ' .. path }
    end
    local pr = pr_by_id(id)
    if not pr then
      return 404, { message = 'PR ' .. id .. ' not found' }
    end
    if method == 'GET' and rest == '' then
      return 200, pr
    elseif method == 'GET' and rest == '/statuses' then
      return 200, { value = { { state = 'succeeded', context = { genre = 'ci', name = 'build' }, description = 'Build passed' } } }
    elseif method == 'GET' and rest == '/threads' then
      return 200, { value = srv.threads }
    elseif method == 'POST' and rest == '/threads' then
      srv.next_thread = srv.next_thread + 1
      local t = {
        id = srv.next_thread,
        publishedDate = '2024-03-14T10:00:00Z',
        lastUpdatedDate = '2024-03-14T10:00:00Z',
        status = body.status,
        threadContext = body.threadContext,
        comments = {},
        isDeleted = false,
      }
      for i, c in ipairs(body.comments or {}) do
        t.comments[i] = F.comment(i, me, c.content, { parentCommentId = c.parentCommentId, publishedDate = '2024-03-14T10:00:00Z' })
      end
      table.insert(srv.threads, t)
      return 200, t
    end
    local tid, trest = rest:match '^/threads/(%d+)(.*)$'
    local t = tid and thread_by_id(tid)
    if not t then
      return 404, { message = 'No route for ' .. method .. ' ' .. path }
    end
    if method == 'POST' and trest == '/comments' then
      srv.next_comment = srv.next_comment + 1
      local c = F.comment(srv.next_comment, me, body.content, { parentCommentId = body.parentCommentId, publishedDate = '2024-03-14T11:00:00Z' })
      table.insert(t.comments, c)
      return 200, c
    elseif method == 'PATCH' and trest == '' then
      t.status = body.status
      return 200, t
    end
    return 404, { message = 'No route for ' .. method .. ' ' .. path }
  end

  --- Replacement for http._transport(args, stdin, on_exit): answers asynchronously like curl.
  function srv.transport(args, stdin, on_exit)
    local method, url, body_file = 'GET', args[#args], nil
    for i, a in ipairs(args) do
      if a == '-X' then
        method = args[i + 1]
      elseif a == '--data-binary' then
        body_file = args[i + 1]:sub(2)
      end
    end
    local body
    if body_file then
      local f = assert(io.open(body_file, 'rb'))
      body = vim.json.decode(f:read '*a')
      f:close()
    end
    local path, query = parse_url(url)
    local req = { method = method, path = path, query = query, body = body, stdin = stdin, args = args }
    table.insert(srv.requests, req)
    local status, data = srv.handle(method, path, query, body)
    local stdout = vim.json.encode(data) .. '\n' .. tostring(status)
    vim.defer_fn(function()
      on_exit { code = 0, stdout = stdout, stderr = '' }
    end, 5)
  end

  --- Requests matching method and a path suffix.
  function srv.find(method, suffix)
    local out = {}
    for _, r in ipairs(srv.requests) do
      if r.method == method and vim.endswith(r.path, suffix) then
        table.insert(out, r)
      end
    end
    return out
  end

  return srv
end

local orig_select, orig_input, orig_notify = vim.ui.select, vim.ui.input, vim.notify

local function cleanup()
  vim.cmd 'stopinsert'
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= '' then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  pcall(vim.cmd, 'silent! tabonly!')
  pcall(vim.cmd, 'silent! only!')
  vim.cmd 'enew!'
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match '^azure%-pr://' then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  vim.ui.select, vim.ui.input, vim.notify = orig_select, orig_input, orig_notify
end

local function items_of(buf)
  return require('azure_pr.ui.detail').get_state(buf).items
end

local function find_line(items, pred)
  local best
  for lnum, item in pairs(items) do
    if pred(item) and (not best or lnum < best) then
      best = lnum
    end
  end
  return best
end

local function buf_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
end

local function current_float_buf()
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(win).relative ~= '' then
    return vim.api.nvim_win_get_buf(win)
  end
end

describe('e2e', function()
  it('list -> group -> filter -> detail -> reply -> status -> comment against a fake Azure DevOps', function()
    cleanup()
    reset_modules()
    local notes = {}
    vim.notify = function(msg, level)
      table.insert(notes, { msg = msg, level = level })
    end

    local srv = fake_server()
    local azure = require 'azure_pr'
    azure.setup { organization = 'myorg', project = 'MyProject', pat = 's3cret-pat', icons = false, list = { layout = 'current' } }
    require('azure_pr.http')._transport = srv.transport
    eq(2, vim.fn.exists ':AzurePR')

    -- :AzurePR list ----------------------------------------------------------
    vim.cmd 'AzurePR list'
    local list = require 'azure_pr.ui.list'
    local lbuf = list.bufnr()
    truthy(lbuf, 'list buffer created')
    truthy(
      wait_for(function()
        return list._view.loaded and not list._view.loading
      end, 3000),
      'list loaded'
    )
    local lreq = srv.find('GET', '/_apis/git/pullrequests')[1]
    eq('active', lreq.query['searchCriteria.status'])
    eq('7.1', lreq.query['api-version'])
    eq('100', lreq.query['$top'])
    -- the PAT travels through stdin (curl -K -), never argv
    contains(lreq.stdin, vim.base64.encode ':s3cret-pat')
    for _, a in ipairs(lreq.args) do
      falsy(a:find('s3cret', 1, true), 'PAT not in argv')
    end
    eq(1, #srv.find('GET', '/_apis/connectionData'))

    local text = buf_text(lbuf)
    contains(text, 'group: repository')
    contains(text, 'api-service')
    contains(text, 'Web App')
    contains(text, 'Add retry policy') -- title column is truncated at 80 columns
    falsy(text:find('Release 1.2', 1, true), 'completed PR not in the active list')
    local groups = {}
    for _, item in pairs(list._view.items) do
      if item.kind == 'group' then
        groups[item.group_key] = true
      end
    end
    truthy(groups['api-service'] and groups['Web App'], 'grouped by repository: ' .. vim.inspect(groups))

    local function shown_ids()
      local ids = {}
      for _, item in pairs(list._view.items) do
        if item.kind == 'pr' then
          ids[#ids + 1] = item.pr.id
        end
      end
      table.sort(ids)
      return ids
    end
    eq({ 101, 102, 103, 104, 105, 106, 109 }, shown_ids())

    -- filters: m (created by me), then text filter via vim.ui.input ------------
    feed 'm'
    eq({ 102, 104 }, shown_ids())
    contains(buf_text(lbuf), 'mine')
    feed 'm'
    vim.ui.input = function(_, cb)
      cb 'retry'
    end
    feed 'f'
    eq({ 101 }, shown_ids())
    contains(buf_text(lbuf), 'text:"retry"')

    -- <CR> on the PR row opens the detail view --------------------------------
    local row = find_line(list._view.items, function(item)
      return item.kind == 'pr' and item.pr.id == 101
    end)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    feed '<CR>'
    local detail = require 'azure_pr.ui.detail'
    local dbuf = vim.api.nvim_get_current_buf()
    eq('azure_pr_detail', vim.bo[dbuf].filetype)
    eq('azure-pr://pr/101', vim.api.nvim_buf_get_name(dbuf))
    eq(2, #vim.api.nvim_tabpage_list_wins(0), 'detail opened in a split next to the list')
    local dwin = vim.api.nvim_get_current_win()
    truthy(
      wait_for(function()
        local st = detail.get_state(dbuf)
        return st and not st.loading and #(st.threads or {}) > 0
      end, 3000),
      'detail loaded'
    )
    eq(1, #srv.find('GET', '/pullRequests/101'))
    eq(1, #srv.find('GET', '/pullRequests/101/threads'))
    eq(1, #srv.find('GET', '/pullRequests/101/statuses'))
    local pol = srv.find('GET', '/_apis/policy/evaluations')[1]
    eq('vstfs:///CodeReview/CodeReviewId/' .. F.REPO_API.project.id .. '/101', pol.query.artifactId)
    eq('7.1-preview.1', pol.query['api-version'])

    local dtext = buf_text(dbuf)
    contains(dtext, 'Add retry policy to HTTP client')
    contains(dtext, 'Please add a test')
    contains(dtext, 'for the timeout path')
    contains(dtext, 'Agreed, will fix')
    contains(dtext, 'src/http/client.lua:42')
    contains(dtext, 'Looks good overall')
    contains(dtext, 'ci/build')
    contains(dtext, 'Minimum number of reviewers')
    falsy(dtext:find('voted 10', 1, true), 'system thread hidden')
    falsy(dtext:find('oops', 1, true), 'deleted thread hidden')

    -- reply to Jan's comment through the input float ---------------------------
    local cline = find_line(items_of(dbuf), function(item)
      return item.kind == 'comment' and item.thread.id == 11 and item.comment.id == 1
    end)
    truthy(cline, 'comment line found')
    vim.api.nvim_win_set_cursor(dwin, { cline, 0 })
    feed 'r'
    local fbuf = current_float_buf()
    truthy(fbuf, 'input float opened')
    truthy(vim.api.nvim_buf_get_name(fbuf):match '^azure%-pr://comment/%d+$', 'input buffer name')
    vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { 'Test added in abc123.', '', 'Thanks!' })
    vim.cmd 'stopinsert'
    feed '<C-s>'
    falsy(vim.api.nvim_buf_is_valid(fbuf), 'input float closed after submit')
    truthy(
      wait_for(function()
        return #srv.find('POST', '/threads/11/comments') == 1
      end, 3000),
      'reply POSTed'
    )
    local post = srv.find('POST', '/threads/11/comments')[1]
    eq({ content = 'Test added in abc123.\n\nThanks!', parentCommentId = 1, commentType = 1 }, post.body)
    eq('7.1', post.query['api-version'])
    -- detail refreshes and shows the new reply
    truthy(
      wait_for(function()
        return buf_text(dbuf):find('Test added in abc123.', 1, true) ~= nil and not detail.get_state(dbuf).loading
      end, 3000),
      'reply rendered after refresh'
    )
    contains(buf_text(dbuf), 'Thanks!')

    -- change thread status to fixed ------------------------------------------
    vim.api.nvim_set_current_win(dwin)
    local tline = find_line(items_of(dbuf), function(item)
      return item.kind == 'thread' and item.thread.id == 11
    end)
    vim.api.nvim_win_set_cursor(dwin, { tline, 0 })
    local offered
    vim.ui.select = function(items, _, cb)
      offered = items
      cb 'fixed'
    end
    feed 's'
    contains(offered, 'fixed')
    truthy(
      wait_for(function()
        return #srv.find('PATCH', '/threads/11') == 1
      end, 3000),
      'status PATCHed'
    )
    eq({ status = 'fixed' }, srv.find('PATCH', '/threads/11')[1].body)
    truthy(
      wait_for(function()
        local st = detail.get_state(dbuf)
        if st.loading then
          return false
        end
        for _, t in ipairs(st.threads) do
          if t.id == 11 then
            return t.status == 'fixed'
          end
        end
      end, 3000),
      'thread status refreshed'
    )
    contains(buf_text(dbuf), '[fixed]')
    if vim.env.AZURE_PR_E2E_DUMP then
      print('\n--- list ---\n' .. buf_text(lbuf) .. '\n--- detail ---\n' .. buf_text(dbuf))
    end

    -- new general comment -----------------------------------------------------
    vim.api.nvim_set_current_win(dwin)
    feed 'c'
    fbuf = current_float_buf()
    truthy(fbuf, 'comment float opened')
    vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { 'LGTM once CI is green' })
    vim.cmd 'stopinsert'
    feed '<C-s>'
    truthy(
      wait_for(function()
        return #srv.find('POST', '/pullRequests/101/threads') == 1
      end, 3000),
      'thread POSTed'
    )
    eq({
      comments = { { parentCommentId = 0, content = 'LGTM once CI is green', commentType = 1 } },
      status = 'active',
    }, srv.find('POST', '/pullRequests/101/threads')[1].body)
    truthy(
      wait_for(function()
        return buf_text(dbuf):find('LGTM once CI is green', 1, true) ~= nil
      end, 3000),
      'new thread rendered'
    )

    -- no errors were reported along the way
    for _, n in ipairs(notes) do
      falsy(n.level == vim.log.levels.ERROR, 'unexpected error: ' .. tostring(n.msg))
    end

    -- :AzurePR refresh inside the detail refetches it
    local before = #srv.find('GET', '/pullRequests/101/threads')
    vim.api.nvim_set_current_win(dwin)
    vim.cmd 'AzurePR refresh'
    truthy(
      wait_for(function()
        return #srv.find('GET', '/pullRequests/101/threads') == before + 1
      end, 3000),
      'refresh refetched threads'
    )
    wait_for(function()
      return not detail.get_state(dbuf).loading
    end, 3000)

    cleanup()
  end)

  it('reports HTTP errors from the fake server in the list view', function()
    cleanup()
    reset_modules()
    local notes = {}
    vim.notify = function(msg, level)
      table.insert(notes, { msg = msg, level = level })
    end
    local azure = require 'azure_pr'
    azure.setup { organization = 'myorg', project = 'MyProject', pat = 'x', icons = false, list = { layout = 'current' } }
    require('azure_pr.http')._transport = function(_, _, on_exit)
      vim.defer_fn(function()
        on_exit { code = 0, stdout = '{"message":"TF400813: not authorized"}\n401', stderr = '' }
      end, 5)
    end
    vim.cmd 'AzurePR list'
    local list = require 'azure_pr.ui.list'
    truthy(wait_for(function()
      return list._view.error ~= nil and not list._view.loading
    end, 3000))
    local text = buf_text(list.bufnr())
    contains(text, 'HTTP 401')
    contains(text, 'TF400813')
    contains(text, 'Press R to retry')
    local errors = vim.tbl_filter(function(n)
      return n.level == vim.log.levels.ERROR
    end, notes)
    truthy(#errors >= 1, 'error notification')
    cleanup()
  end)
end)
