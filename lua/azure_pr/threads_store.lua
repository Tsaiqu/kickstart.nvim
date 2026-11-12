-- Shared per-PR store of normalized comment threads (system threads excluded, never filtered by
-- the detail view's toggles). Written by the detail view and by `fetch`; read by inline markers.
local M = {}

---@type table<string, { pr: table, threads: table[] }>
local store = {}
---@type table<string, fun(err: string|nil, threads: table[]|nil)[]>
local inflight = {}

local function key(id)
  return tostring(id)
end

---@param pr table
---@param threads_all table[] normalized with include_system = false
function M.set(pr, threads_all)
  store[key(pr.id)] = { pr = pr, threads = threads_all }
  vim.api.nvim_exec_autocmds('User', { pattern = 'AzurePRThreadsChanged', modeline = false, data = { pr_id = pr.id } })
end

---@param pr_id integer|string
---@return { pr: table, threads: table[] }|nil
function M.get(pr_id)
  return store[key(pr_id)]
end

--- Fetch threads of a PR, normalize, store. Concurrent calls for one PR share one request.
---@param pr table
---@param cb fun(err: string|nil, threads: table[]|nil)
function M.fetch(pr, cb)
  local k = key(pr.id)
  if inflight[k] then
    table.insert(inflight[k], cb)
    return
  end
  inflight[k] = { cb }
  local repo_id = pr.repository and pr.repository.id
  require('azure_pr.api').list_threads(repo_id, pr.id, function(err, raw)
    local waiting = inflight[k] or {}
    inflight[k] = nil
    local threads
    if not err then
      threads = require('azure_pr.models').normalize_threads(raw or {}, { include_system = false })
      M.set(pr, threads)
    end
    for _, f in ipairs(waiting) do
      f(err, threads)
    end
  end)
end

function M.clear()
  store = {}
  inflight = {}
end

return M
