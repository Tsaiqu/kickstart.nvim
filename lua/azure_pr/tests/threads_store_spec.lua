---@diagnostic disable: duplicate-set-field, need-check-nil
local F = require 'azure_pr.tests.fixtures'

local function fresh(list_threads)
  package.loaded['azure_pr.threads_store'] = nil
  package.loaded['azure_pr.api'] = { list_threads = list_threads }
  return require 'azure_pr.threads_store'
end

describe('threads_store', function()
  it('set + get returns pr and threads, clear empties it', function()
    local S = fresh(function() end)
    local pr = { id = 7 }
    S.set(pr, { { id = 1 } })
    local e = S.get(7)
    eq(pr, e.pr)
    eq(1, #e.threads)
    eq(1, #S.get('7').threads)
    S.clear()
    eq(nil, S.get(7))
  end)

  it('set fires User AzurePRThreadsChanged with pr_id', function()
    local S = fresh(function() end)
    local got
    local id = vim.api.nvim_create_autocmd('User', {
      pattern = 'AzurePRThreadsChanged',
      callback = function(ev)
        got = ev.data
      end,
    })
    S.set({ id = 9 }, {})
    vim.api.nvim_del_autocmd(id)
    eq({ pr_id = 9 }, got)
  end)

  it('parallel fetches for one PR share a single request', function()
    local calls, pending = 0, nil
    local S = fresh(function(_, _, cb)
      calls = calls + 1
      pending = cb
    end)
    local pr = { id = 5, repository = { id = 'r' } }
    local r1, r2
    S.fetch(pr, function(err, t)
      r1 = { err, t }
    end)
    S.fetch(pr, function(err, t)
      r2 = { err, t }
    end)
    eq(1, calls)
    pending(nil, F.threads())
    truthy(r1 and r2)
    eq(nil, r1[1])
    truthy(#r1[2] > 0)
    eq(#r1[2], #S.get(5).threads)
    -- after completion a new fetch makes a new request
    S.fetch(pr, function() end)
    eq(2, calls)
  end)

  it('fetch passes errors to every callback and does not set', function()
    local pending
    local S = fresh(function(_, _, cb)
      pending = cb
    end)
    local pr = { id = 5, repository = { id = 'r' } }
    local errs = {}
    S.fetch(pr, function(err)
      table.insert(errs, err)
    end)
    S.fetch(pr, function(err)
      table.insert(errs, err)
    end)
    pending 'boom'
    eq({ 'boom', 'boom' }, errs)
    eq(nil, S.get(5))
  end)
end)
