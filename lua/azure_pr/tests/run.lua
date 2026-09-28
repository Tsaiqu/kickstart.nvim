-- Minimal headless test runner for azure_pr.
-- Usage:
--   nvim --headless --clean -u NONE --cmd 'set rtp^=~/.config/nvim' -l ~/.config/nvim/lua/azure_pr/tests/run.lua [pattern]
local root = debug.getinfo(1, 'S').source:sub(2):match '(.*)/tests/run%.lua$'
local config_dir = vim.fn.fnamemodify(root, ':h:h')
vim.opt.rtp:prepend(config_dir)
package.path = config_dir .. '/lua/?.lua;' .. config_dir .. '/lua/?/init.lua;' .. package.path

local T = { passed = 0, failed = 0, failures = {} }
local stack = {}

local function fmt(v)
  return vim.inspect(v)
end

_G.describe = function(name, fn)
  table.insert(stack, name)
  fn()
  table.remove(stack)
end

_G.it = function(name, fn)
  local full = table.concat(stack, ' > ') .. ' > ' .. name
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    T.passed = T.passed + 1
    io.stdout:write('  ok   ' .. full .. '\n')
  else
    T.failed = T.failed + 1
    table.insert(T.failures, { name = full, err = err })
    io.stdout:write('  FAIL ' .. full .. '\n')
  end
end

_G.eq = function(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error((msg and (msg .. ': ') or '') .. 'expected ' .. fmt(expected) .. ' got ' .. fmt(actual), 2)
  end
end

_G.truthy = function(v, msg)
  if not v then
    error((msg or 'expected truthy') .. ' got ' .. fmt(v), 2)
  end
end

_G.falsy = function(v, msg)
  if v then
    error((msg or 'expected falsy') .. ' got ' .. fmt(v), 2)
  end
end

_G.contains = function(haystack, needle, msg)
  if type(haystack) == 'string' then
    if not haystack:find(needle, 1, true) then
      error((msg and (msg .. ': ') or '') .. fmt(haystack) .. ' does not contain ' .. fmt(needle), 2)
    end
  else
    for _, v in ipairs(haystack) do
      if vim.deep_equal(v, needle) then
        return
      end
    end
    error((msg and (msg .. ': ') or '') .. fmt(haystack) .. ' does not contain ' .. fmt(needle), 2)
  end
end

--- Wait (pumping the event loop) until fn() is truthy or timeout ms elapse.
_G.wait_for = function(fn, timeout)
  return vim.wait(timeout or 2000, fn, 10)
end

--- Unload all azure_pr modules so each spec starts clean.
_G.reset_modules = function()
  for name in pairs(package.loaded) do
    if name == 'azure_pr' or name:match '^azure_pr%.' then
      package.loaded[name] = nil
    end
  end
end

local pattern = _G.arg and _G.arg[1] or nil
local specs = vim.fn.glob(root .. '/tests/*_spec.lua', false, true)
table.sort(specs)
for _, file in ipairs(specs) do
  if not pattern or file:find(pattern, 1, true) then
    io.stdout:write(vim.fn.fnamemodify(file, ':t') .. '\n')
    reset_modules()
    local ok, err = xpcall(dofile, debug.traceback, file)
    if not ok then
      T.failed = T.failed + 1
      table.insert(T.failures, { name = file .. ' (load)', err = err })
      io.stdout:write('  FAIL loading ' .. file .. '\n')
    end
  end
end

io.stdout:write(string.format('\n%d passed, %d failed\n', T.passed, T.failed))
for _, f in ipairs(T.failures) do
  io.stdout:write('\n--- ' .. f.name .. '\n' .. tostring(f.err) .. '\n')
end
os.exit(T.failed == 0 and 0 or 1)
