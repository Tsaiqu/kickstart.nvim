-- Shared user actions (comment, reply, vote, thread status, browser, checkout, ...) used by the
-- list view, the detail view and the :AzurePR command.
--
-- Callback convention: every `cb` is optional and is called as `cb(err, result)` once the
-- underlying API call finished (always on the main loop). When the user cancels a prompt
-- (input float, vim.ui.select, confirmation) the callback is NOT called. Errors and successes
-- are also reported through `util.notify`, so callers typically only use `cb` to refresh.
local api = require 'azure_pr.api'
local models = require 'azure_pr.models'
local state = require 'azure_pr.state'
local util = require 'azure_pr.util'

local M = {}

local levels = vim.log.levels

local function input()
  return require 'azure_pr.ui.input'
end

local function notify(msg, level)
  util.notify(msg, level)
end

--- Wrap an optional callback, reporting errors / success messages.
---@param cb fun(err: string|nil, result: any)|nil
---@param success_msg string|nil
---@param fail_prefix string
local function finish(cb, success_msg, fail_prefix)
  return function(err, result)
    if err then
      notify(fail_prefix .. ': ' .. tostring(err), levels.ERROR)
    elseif success_msg then
      notify(success_msg, levels.INFO)
    end
    if cb then
      cb(err, result)
    end
  end
end

--- Open the comment editor and send its text with `send(text, done)`. When the request fails the
--- typed text is not lost: it goes to the unnamed register and, when the user is still in the
--- window they submitted from (normal mode), the editor reopens pre-filled with it (without
--- entering insert mode). A failure can arrive up to `timeout` later, so when the user has moved on
--- the editor is NOT popped up over their work: the text is stored as a draft (keyed by the editor
--- title, i.e. PR/thread/comment) and repeating the action reopens the editor with it.
--- `cb(err, result)` gets the final outcome of each attempt.
---@param input_opts table options for ui.input.open (title, initial, ...)
---@param send fun(text: string, done: fun(err: string|nil, result: any))
---@param success_msg string
---@param fail_prefix string
---@param cb fun(err: string|nil, result: any)|nil
local function edit_and_send(input_opts, send, success_msg, fail_prefix, cb)
  state.drafts = state.drafts or {}
  local key = input_opts.title or ''
  local draft = state.drafts[key]
  if draft then
    state.drafts[key] = nil
    input_opts = vim.tbl_extend('force', input_opts, { initial = draft })
  end
  input().open(input_opts, function(text)
    local origin_win = vim.api.nvim_get_current_win()
    local origin_buf = vim.api.nvim_get_current_buf()
    send(text, function(err, result)
      if not err then
        return finish(cb, success_msg, fail_prefix)(nil, result)
      end
      pcall(vim.fn.setreg, '"', text)
      local still_here = vim.api.nvim_get_current_win() == origin_win and vim.api.nvim_get_current_buf() == origin_buf and vim.fn.mode() == 'n'
      if still_here then
        notify(fail_prefix .. ': ' .. tostring(err) .. ' (text kept in register ", editor reopened)', levels.ERROR)
      else
        state.drafts[key] = text
        notify(fail_prefix .. ': ' .. tostring(err) .. ' (text kept in register " and as a draft: repeat the action to reopen it)', levels.ERROR)
      end
      if cb then
        cb(err, result)
      end
      if still_here then
        edit_and_send(vim.tbl_extend('force', input_opts, { initial = text, no_insert = true }), send, success_msg, fail_prefix, cb)
      end
    end)
  end)
end

--- Refresh an open detail view of this PR (after commenting/voting from a file buffer or the list).
---@param pr AzurePR
function M.refresh_detail_of(pr)
  local detail = package.loaded['azure_pr.ui.detail']
  if type(detail) ~= 'table' or not detail.find_pr or not detail.refresh then
    return
  end
  if type(pr) ~= 'table' or pr.id == nil then
    return
  end
  local ok, found, dbuf = pcall(detail.find_pr, pr.id)
  if ok and found and dbuf then
    pcall(detail.refresh, dbuf)
  end
end

local function lower(s)
  return type(s) == 'string' and s:lower() or s
end

---@param pr AzurePR|nil
---@return string|nil repo_id, string|nil err
local function repo_id_of(pr)
  if type(pr) ~= 'table' or not pr.id then
    return nil, 'No pull request selected'
  end
  local repo = pr.repository or {}
  local id = repo.id or repo.name
  if not id then
    return nil, 'Pull request !' .. tostring(pr.id) .. ' has no repository information'
  end
  return id
end

local function pr_label(pr)
  local title = pr.title and pr.title ~= '' and (' ' .. util.truncate(pr.title, 50)) or ''
  return '!' .. tostring(pr.id) .. title
end

--- Current user (state cache, else api.get_current_user). cb(err, user)
---@param cb fun(err: string|nil, user: table|nil)
function M.get_user(cb)
  if state.user and state.user.id then
    local user = state.user
    return vim.schedule(function()
      cb(nil, user)
    end)
  end
  api.get_current_user(function(err, user)
    if not err and user then
      state.user = user
    end
    cb(err, user)
  end)
end

-- ---------------------------------------------------------------------------
-- git helpers
-- ---------------------------------------------------------------------------

--- Test seam: run git asynchronously. `cb(code, stdout, stderr)` runs on the main loop.
---@param args string[] arguments after `git`
---@param opts { cwd: string|nil, timeout: integer|nil }|nil
---@param cb fun(code: integer, stdout: string, stderr: string)
function M._git(args, opts, cb)
  opts = opts or {}
  local cmd = vim.list_extend({ 'git' }, args)
  -- network commands get a longer timeout; GIT_TERMINAL_PROMPT=0 stops git from prompting for
  -- credentials on /dev/tty (it would draw over and read from Neovim's TUI).
  local timeout = opts.timeout or ((args[1] == 'fetch' or args[1] == 'pull') and 60000 or 10000)
  local ok, err = pcall(vim.system, cmd, {
    text = true,
    cwd = opts.cwd,
    env = { GIT_TERMINAL_PROMPT = '0', GCM_INTERACTIVE = 'never' },
    timeout = timeout,
  }, function(res)
    local stderr = res.stderr or ''
    if res.code == 124 and (res.signal == 15 or res.signal == 9) then
      stderr = 'git '
        .. tostring(args[1])
        .. ' timed out after '
        .. math.floor(timeout / 1000)
        .. 's'
        .. (vim.trim(stderr) ~= '' and (': ' .. vim.trim(stderr)) or '')
    end
    vim.schedule(function()
      cb(res.code, res.stdout or '', stderr)
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(-1, '', 'failed to run git: ' .. tostring(err))
    end)
  end
end

local function git_err(stderr, fallback)
  stderr = vim.trim(stderr or '')
  return stderr ~= '' and stderr or fallback
end

--- Directory to run git in for a buffer (its file's directory) or cwd.
local function dir_of(file)
  if file and file ~= '' then
    local dir = vim.fn.fnamemodify(file, ':p:h')
    if vim.fn.isdirectory(dir) == 1 then
      return dir
    end
  end
  return vim.fn.getcwd()
end

-- ---------------------------------------------------------------------------
-- Comments
-- ---------------------------------------------------------------------------

--- New general comment thread on a PR.
---@param pr AzurePR
---@param cb fun(err: string|nil, thread: table|nil)|nil
function M.comment(pr, cb)
  local repo_id, err = repo_id_of(pr)
  if not repo_id then
    return notify(err, levels.WARN)
  end
  edit_and_send({ title = ' New comment on ' .. pr_label(pr) .. ' ' }, function(text, done)
    api.create_thread(repo_id, pr.id, { content = text, status = 'active' }, done)
  end, 'Comment added to !' .. pr.id, 'Failed to add comment', cb)
end

--- Reply to a thread. Parent = `comment` (under cursor) or the thread's first comment.
---@param pr AzurePR
---@param thread table normalized thread
---@param comment table|nil normalized comment
---@param cb fun(err: string|nil, comment: table|nil)|nil
function M.reply(pr, thread, comment, cb)
  local repo_id, err = repo_id_of(pr)
  if not repo_id then
    return notify(err, levels.WARN)
  end
  if type(thread) ~= 'table' or not thread.id then
    return notify('No comment thread under cursor', levels.WARN)
  end
  local parent = comment or (thread.comments and thread.comments[1]) or nil
  local parent_id = parent and parent.id or 1
  local who = parent and parent.author and parent.author.name
  local title = who and (' Reply to ' .. who .. ' ') or (' Reply to thread #' .. thread.id .. ' ')
  edit_and_send({ title = title }, function(text, done)
    api.reply(repo_id, pr.id, thread.id, text, parent_id, done)
  end, 'Reply added', 'Failed to reply', cb)
end

--- Is `comment` authored by `user`?
local function is_own(comment, user)
  return user and comment and comment.author and comment.author.id and lower(comment.author.id) == lower(user.id) or false
end

--- Common checks for edit/delete; calls fn(repo_id) when the comment belongs to the current user.
local function with_own_comment(pr, thread, comment, verb, fn)
  local repo_id, err = repo_id_of(pr)
  if not repo_id then
    return notify(err, levels.WARN)
  end
  if type(thread) ~= 'table' or not thread.id or type(comment) ~= 'table' or not comment.id then
    return notify('No comment under cursor', levels.WARN)
  end
  if comment.is_deleted then
    return notify('Comment is already deleted', levels.WARN)
  end
  M.get_user(function(uerr, user)
    if uerr or not user then
      return notify('Cannot determine current user: ' .. tostring(uerr), levels.ERROR)
    end
    if not is_own(comment, user) then
      return notify('You can only ' .. verb .. ' your own comments', levels.WARN)
    end
    fn(repo_id)
  end)
end

--- Edit own comment (opens the editor pre-filled with the current content).
---@param pr AzurePR
---@param thread table
---@param comment table
---@param cb fun(err: string|nil, comment: table|nil)|nil
function M.edit_comment(pr, thread, comment, cb)
  with_own_comment(pr, thread, comment, 'edit', function(repo_id)
    edit_and_send({ title = ' Edit comment ', initial = comment.content or '' }, function(text, done)
      api.update_comment(repo_id, pr.id, thread.id, comment.id, text, done)
    end, 'Comment updated', 'Failed to update comment', cb)
  end)
end

--- Delete own comment (asks for confirmation).
---@param pr AzurePR
---@param thread table
---@param comment table
---@param cb fun(err: string|nil)|nil
function M.delete_comment(pr, thread, comment, cb)
  with_own_comment(pr, thread, comment, 'delete', function(repo_id)
    local preview = util.truncate((util.split_lines(comment.content or '')[1] or ''), 40)
    input().confirm('Delete comment "' .. preview .. '"?', function(yes)
      if not yes then
        return
      end
      api.delete_comment(repo_id, pr.id, thread.id, comment.id, finish(cb, 'Comment deleted', 'Failed to delete comment'))
    end)
  end)
end

--- Change the status of a thread (vim.ui.select over models.THREAD_STATUSES).
---@param pr AzurePR
---@param thread table
---@param cb fun(err: string|nil, thread: table|nil)|nil
function M.set_thread_status(pr, thread, cb)
  local repo_id, err = repo_id_of(pr)
  if not repo_id then
    return notify(err, levels.WARN)
  end
  if type(thread) ~= 'table' or not thread.id then
    return notify('No comment thread under cursor', levels.WARN)
  end
  vim.ui.select(models.THREAD_STATUSES, {
    prompt = 'Thread status (now: ' .. tostring(thread.status) .. ')',
    format_item = function(s)
      return s == thread.status and (s .. '  (current)') or s
    end,
  }, function(choice)
    if not choice or choice == thread.status then
      return
    end
    api.update_thread_status(repo_id, pr.id, thread.id, choice, finish(cb, 'Thread status set to ' .. choice, 'Failed to change thread status'))
  end)
end

-- ---------------------------------------------------------------------------
-- Voting
-- ---------------------------------------------------------------------------

--- Vote choices in menu order.
M.VOTE_CHOICES = { 10, 5, -5, -10, 0 }

local VOTE_MENU_LABELS = {
  [10] = 'Approve',
  [5] = 'Approve with suggestions',
  [-5] = 'Wait for author',
  [-10] = 'Reject',
  [0] = 'Reset vote',
}

--- Update the PR table in place after a successful vote so views can re-render without refetch.
local function apply_vote_locally(pr, user, vote)
  pr.reviewers = pr.reviewers or {}
  local r = models.find_reviewer(pr, user.id)
  if r then
    r.vote = vote
  else
    table.insert(pr.reviewers, {
      id = user.id,
      name = user.name or user.unique_name or 'Me',
      unique_name = user.unique_name,
      vote = vote,
      is_required = false,
      is_container = false,
      has_declined = false,
    })
  end
  pr.review_state = models.compute_review_state(pr.status, pr.is_draft, pr.reviewers)
end

--- Vote menu (approve / approve with suggestions / wait / reject / reset) as the current user.
---@param pr AzurePR
---@param cb fun(err: string|nil, reviewer: table|nil)|nil
function M.vote(pr, cb)
  local repo_id, err = repo_id_of(pr)
  if not repo_id then
    return notify(err, levels.WARN)
  end
  if pr.status and pr.status ~= 'active' then
    return notify('Cannot vote on a ' .. pr.status .. ' pull request', levels.WARN)
  end
  M.get_user(function(uerr, user)
    if uerr or not user then
      return notify('Cannot determine current user: ' .. tostring(uerr), levels.ERROR)
    end
    local current = models.my_vote(pr, user.id)
    vim.ui.select(M.VOTE_CHOICES, {
      prompt = 'Vote on ' .. pr_label(pr),
      format_item = function(v)
        local label = VOTE_MENU_LABELS[v] or tostring(v)
        return v == current and (label .. '  (current)') or label
      end,
    }, function(choice)
      if choice == nil then
        return
      end
      -- keep `isRequired` (the PUT resets omitted fields); nothing extra when not a reviewer yet
      local me = models.find_reviewer(pr, user.id)
      local vote_opts = me and { is_required = me.is_required == true } or {}
      api.vote(repo_id, pr.id, user.id, choice, vote_opts, function(verr, result)
        if not verr then
          apply_vote_locally(pr, user, choice)
          -- the detail view holds its own copy of the PR: keep the list's copy in sync too
          for _, other in ipairs(state.prs or {}) do
            if other ~= pr and other.id == pr.id then
              apply_vote_locally(other, user, choice)
            end
          end
          local ok_list, list = pcall(require, 'azure_pr.ui.list')
          if ok_list and list.bufnr and list.bufnr() then
            pcall(list.render)
          end
        end
        finish(cb, 'Vote on !' .. pr.id .. ': ' .. models.vote_label(choice), 'Failed to vote')(verr, result)
      end)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Browser / clipboard
-- ---------------------------------------------------------------------------

---@param pr AzurePR
---@return string|nil
local function url_of(pr)
  if type(pr) ~= 'table' then
    return nil
  end
  pr.url = pr.url or api.web_url(pr)
  return pr.url
end

--- Open the PR in the browser (vim.ui.open).
---@param pr AzurePR
function M.open_in_browser(pr)
  local url = url_of(pr)
  if not url then
    return notify('Cannot determine the web URL of this pull request', levels.WARN)
  end
  -- vim.ui.open returns `nil, errmsg` (it does not throw) when no opener is found
  local ok, obj, oerr = pcall(vim.ui.open, url)
  if not ok or obj == nil then
    local msg = not ok and obj or oerr
    return notify('Failed to open browser: ' .. tostring(msg or 'unknown error') .. ' (URL: ' .. url .. ')', levels.ERROR)
  end
  if type(obj) == 'table' and type(obj.wait) == 'function' then
    -- report an opener that exits non-zero, without blocking the UI
    local timer = assert((vim.uv or vim.loop).new_timer())
    local waited = 0
    timer:start(
      200,
      200,
      vim.schedule_wrap(function()
        waited = waited + 200
        local done = type(obj.is_closing) ~= 'function' or obj:is_closing()
        if not done and waited < 10000 then
          return
        end
        timer:stop()
        timer:close()
        if not done then
          return
        end
        local okw, res = pcall(obj.wait, obj, 0)
        if okw and type(res) == 'table' and res.code and res.code ~= 0 then
          local stderr = vim.trim(res.stderr or '')
          notify('Failed to open browser (opener exited with code ' .. res.code .. (stderr ~= '' and (': ' .. stderr) or '') .. ') URL: ' .. url, levels.ERROR)
        end
      end)
    )
  end
end

--- Yank the PR URL into the `+` (if available) and unnamed registers.
---@param pr AzurePR
---@return string|nil url
function M.yank_url(pr)
  local url = url_of(pr)
  if not url then
    notify('Cannot determine the web URL of this pull request', levels.WARN)
    return nil
  end
  pcall(vim.fn.setreg, '+', url)
  vim.fn.setreg('"', url)
  notify('Copied ' .. url, levels.INFO)
  return url
end

-- ---------------------------------------------------------------------------
-- Checkout
-- ---------------------------------------------------------------------------

--- Checkout the PR's source branch in cwd, after confirming:
--- `git fetch origin +refs/heads/<b>:refs/remotes/origin/<b>` (explicit refspec so origin/<b> exists
--- even in single-branch / narrow-refspec clones), then `git switch <b>`. `switch` never treats its
--- argument as a pathspec, so a branch named like a directory cannot silently revert local edits
--- (which `git checkout <b>` would do). Fallbacks: `git switch -c <b> --track origin/<b>`, then
--- `git switch -c <b> origin/<b>` (tracking cannot be set up when the refspec does not cover <b>).
---@param pr AzurePR
---@param cb fun(err: string|nil, branch: string|nil)|nil
function M.checkout(pr, cb)
  local branch = type(pr) == 'table' and pr.source_branch or nil
  if not branch or branch == '' then
    return notify('Pull request has no source branch', levels.WARN)
  end
  if branch:sub(1, 1) == '-' then
    return notify('Refusing to check out suspicious branch name ' .. branch, levels.WARN)
  end
  local done = finish(cb, 'Checked out ' .. branch, 'Checkout failed')
  input().confirm('Checkout branch ' .. branch .. ' (!' .. tostring(pr.id) .. ')?', function(yes)
    if not yes then
      return
    end
    local cwd = vim.fn.getcwd()
    local remote_ref = 'origin/' .. branch
    local attempts = {
      { 'switch', branch },
      { 'switch', '-c', branch, '--track', remote_ref },
      { 'switch', '-c', branch, remote_ref },
    }
    local errors = {}
    local function try(i)
      local args = attempts[i]
      if not args then
        -- "already exists" from the -c fallbacks hides the real reason (e.g. local changes)
        local last = errors[#errors] or ''
        local msg = last:find('already exists', 1, true) and errors[1] or last
        return done(git_err(msg, 'git switch failed'))
      end
      M._git(args, { cwd = cwd }, function(code, _, stderr)
        if code == 0 then
          pcall(vim.cmd.checktime)
          return done(nil, branch)
        end
        table.insert(errors, stderr or '')
        try(i + 1)
      end)
    end
    notify('Fetching ' .. remote_ref .. '…', levels.INFO)
    M._git({ 'fetch', 'origin', '+refs/heads/' .. branch .. ':refs/remotes/' .. remote_ref }, { cwd = cwd }, function(code, _, stderr)
      if code ~= 0 then
        return done(git_err(stderr, 'git fetch failed'))
      end
      try(1)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Current-branch PR & line comments
-- ---------------------------------------------------------------------------

local function select_pr(prs, branch, cb)
  if #prs == 1 then
    return cb(nil, prs[1])
  end
  vim.ui.select(prs, {
    prompt = 'Pull requests for ' .. branch,
    format_item = function(pr)
      return string.format('!%s %s [%s → %s] (%s)', pr.id, pr.title or '', pr.source_branch or '?', pr.target_branch or '?', pr.repository.name or '?')
    end,
  }, function(choice)
    -- cancelled -> cb(nil, nil): callers treat a nil PR without error as "nothing to do"
    cb(nil, choice)
  end)
end

local function filter_repo(prs, repo_name)
  if not repo_name then
    return prs
  end
  local out = {}
  for _, pr in ipairs(prs) do
    if lower(pr.repository and pr.repository.name) == lower(repo_name) then
      table.insert(out, pr)
    end
  end
  return out
end

--- Find the active PR whose source branch is the current git branch.
--- Looks in `state.prs` first, then asks the API (`source_ref`, restricted to the repository of the
--- `origin` remote when that is an Azure DevOps remote). Several matches -> vim.ui.select.
--- `cb(err, pr)`; `pr` is nil without error when the user cancelled the selection.
---@param cb fun(err: string|nil, pr: AzurePR|nil)
---@param opts { cwd: string|nil }|nil
function M.current_branch_pr(cb, opts)
  opts = opts or {}
  local cwd = opts.cwd or vim.fn.getcwd()
  M._git({ 'rev-parse', '--abbrev-ref', 'HEAD' }, { cwd = cwd }, function(code, stdout, stderr)
    local branch = vim.trim(stdout or '')
    if code ~= 0 or branch == '' then
      return cb('Not in a git repository (' .. git_err(stderr, 'git rev-parse failed') .. ')')
    end
    if branch == 'HEAD' then
      return cb 'HEAD is detached: check out a branch to find its pull request'
    end
    M._git({ 'remote', 'get-url', 'origin' }, { cwd = cwd }, function(rcode, rout)
      local remote = rcode == 0 and util.parse_remote(vim.trim(rout or '')) or nil
      local repo_name = remote and remote.repository or nil

      local cached = {}
      for _, pr in ipairs(state.prs or {}) do
        if pr.status == 'active' and pr.source_branch == branch then
          table.insert(cached, pr)
        end
      end
      cached = filter_repo(cached, repo_name)
      if #cached > 0 then
        return select_pr(cached, branch, cb)
      end

      api.list_pull_requests({ status = 'active', source_ref = branch, repository = repo_name }, function(err, raws)
        if err then
          return cb(err)
        end
        local prs = {}
        for _, raw in ipairs(raws or {}) do
          local pr = models.normalize_pr(raw)
          pr.url = pr.url or api.web_url(pr)
          table.insert(prs, pr)
        end
        prs = filter_repo(prs, repo_name)
        if #prs == 0 then
          return cb('No active pull request for branch ' .. branch)
        end
        select_pr(prs, branch, cb)
      end)
    end)
  end)
end

--- Known PR with this id: open detail views first (freshest), then the list state, then review_pr.
local function known_pr(id)
  if id == nil then
    return nil
  end
  local detail = package.loaded['azure_pr.ui.detail']
  if type(detail) == 'table' and detail.find_pr then
    local ok, pr = pcall(detail.find_pr, id)
    if ok and pr then
      return pr
    end
  end
  for _, pr in ipairs(state.prs or {}) do
    if tostring(pr.id) == tostring(id) then
      return pr
    end
  end
  if state.review_pr and tostring(state.review_pr.id) == tostring(id) then
    return state.review_pr
  end
end

--- Pick the PR a line comment goes to. Order:
--- 1. `opts.pr`; 2. `opts.pr_id` (`:AzurePR comment <id>`, fetched when not known);
--- 3. the PR whose detail view opened this file buffer (`b:azure_pr_id`);
--- 4. the PR of the current git branch; when there is none: the most recently used detail view's PR,
---    otherwise a vim.ui.select over the loaded active PRs.
local function comment_target(opts, buf, cwd, cb)
  if opts.pr then
    return cb(nil, opts.pr)
  end
  if opts.pr_id ~= nil then
    local pr = known_pr(opts.pr_id)
    if pr then
      return cb(nil, pr)
    end
    local id = tonumber(opts.pr_id)
    if not id then
      return cb('Invalid pull request id: ' .. tostring(opts.pr_id))
    end
    return api.get_pull_request_by_id(id, function(err, raw)
      if err or not raw then
        return cb('Could not load pull request !' .. id .. ': ' .. tostring(err))
      end
      local fetched = models.normalize_pr(raw)
      fetched.url = fetched.url or api.web_url(fetched)
      cb(nil, fetched)
    end)
  end
  local ok_var, buf_pr_id = pcall(function()
    return vim.b[buf].azure_pr_id
  end)
  local from_buf = ok_var and known_pr(buf_pr_id) or nil
  if from_buf then
    return cb(nil, from_buf)
  end
  M.current_branch_pr(function(err, pr)
    if not err then
      return cb(nil, pr, true) -- nil pr = selection cancelled; true = PR of the checked-out branch
    end
    if state.review_pr then
      notify(err .. ': commenting on !' .. tostring(state.review_pr.id) .. ' (last opened PR)', levels.INFO)
      return cb(nil, state.review_pr)
    end
    local active = vim.tbl_filter(function(p)
      return p.status == 'active'
    end, state.prs or {})
    if #active == 0 then
      return cb(err)
    end
    vim.ui.select(active, {
      prompt = err .. ' – comment on which PR?',
      format_item = function(p)
        return string.format('!%s %s (%s)', p.id, p.title or '', p.repository and p.repository.name or '?')
      end,
    }, function(choice)
      cb(nil, choice)
    end)
  end, { cwd = cwd })
end

--- Line numbers of the local file only match the PR when its source branch is checked out.
--- `cb(true)` when HEAD is the PR's source branch or the user confirms commenting anyway.
---@param pr AzurePR
---@param cwd string
---@param cb fun(proceed: boolean)
function M.ensure_on_source_branch(pr, cwd, cb)
  M._git({ 'rev-parse', '--abbrev-ref', 'HEAD' }, { cwd = cwd }, function(code, stdout)
    local branch = code == 0 and vim.trim(stdout or '') or ''
    if pr.source_branch and branch == pr.source_branch then
      return cb(true)
    end
    local head = branch ~= '' and branch or '?'
    input().confirm(
      string.format(
        'HEAD is %s, not %s (!%s): line numbers may not match the PR (C in the list/detail checks it out). Comment anyway?',
        head,
        tostring(pr.source_branch or '?'),
        tostring(pr.id)
      ),
      cb
    )
  end)
end

--- Comment on a line (or range) of the current file buffer (PR chosen by `comment_target`).
--- opts: `{ line1?, line2? (visual/cmd range; default cursor line), buf? (default current),
---          pr? (skip lookup), pr_id? (from `:AzurePR comment <id>`), cb? }`.
---@param opts table|nil
function M.comment_on_line(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return notify('Invalid buffer', levels.WARN)
  end
  local file = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= '' or file == '' then
    return notify('Line comments work only in a file buffer', levels.WARN)
  end
  file = vim.fn.resolve(vim.fn.fnamemodify(file, ':p'))

  local line1, line2 = opts.line1, opts.line2
  if not line1 then
    local win = vim.fn.bufwinid(buf)
    line1 = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or 1
  end
  line2 = line2 or line1
  if line2 < line1 then
    line1, line2 = line2, line1
  end

  -- anchor the whole last line: Azure offsets are 1-based characters, end offset is exclusive
  local last_text = vim.api.nvim_buf_get_lines(buf, line2 - 1, line2, false)[1] or ''
  local end_offset = vim.fn.strchars(last_text) + 1

  local cwd = dir_of(file)
  M._git({ 'rev-parse', '--show-toplevel' }, { cwd = cwd }, function(code, stdout, stderr)
    local root = vim.trim(stdout or '')
    if code ~= 0 or root == '' then
      return notify('File is not inside a git repository (' .. git_err(stderr, 'git rev-parse failed') .. ')', levels.WARN)
    end
    root = vim.fn.resolve(vim.fs.normalize(root)):gsub('/+$', '')
    local norm = vim.fs.normalize(file)
    if norm:sub(1, #root + 1) ~= root .. '/' then
      return notify('File ' .. norm .. ' is outside git root ' .. root, levels.WARN)
    end
    local rel = norm:sub(#root + 2)

    local function send_to(pr, repo_id)
      local loc = rel .. ':' .. line1 .. (line2 ~= line1 and ('-' .. line2) or '')
      edit_and_send(
        { title = ' Comment on ' .. loc .. ' (!' .. pr.id .. ') ' },
        function(text, done)
          api.create_thread(
            repo_id,
            pr.id,
            { content = text, status = 'active', file_path = rel, line = line1, end_line = line2, end_offset = end_offset },
            done
          )
        end,
        'Comment added on ' .. loc .. ' (!' .. pr.id .. ')',
        'Failed to add comment',
        function(cerr, result)
          if not cerr then
            M.refresh_detail_of(pr)
          end
          if opts.cb then
            opts.cb(cerr, result)
          end
        end
      )
    end

    local function with_pr(err, pr, on_branch)
      if err then
        return notify(err, levels.WARN)
      end
      if not pr then
        return
      end
      local repo_id, rerr = repo_id_of(pr)
      if not repo_id then
        return notify(rerr, levels.WARN)
      end
      if on_branch then
        return send_to(pr, repo_id)
      end
      M.ensure_on_source_branch(pr, cwd, function(proceed)
        if proceed then
          send_to(pr, repo_id)
        end
      end)
    end

    comment_target(opts, buf, cwd, with_pr)
  end)
end

return M
