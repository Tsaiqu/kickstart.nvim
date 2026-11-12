---@diagnostic disable: duplicate-set-field, need-check-nil, param-type-mismatch, assign-type-mismatch, redundant-parameter, cast-local-type, missing-parameter
local frame = require 'azure_pr.ui.frame'
local hl = require 'azure_pr.ui.highlights'

local nerd = hl.icons(true)
local ascii = hl.icons(false)

local function texts(segs)
  local t = {}
  for _, s in ipairs(segs) do
    t[#t + 1] = s[1]
  end
  return table.concat(t)
end

local function width(segs)
  return vim.fn.strdisplaywidth(texts(segs))
end

describe('frame.top', function()
  it('draws a width-exact top border with the title group kept', function()
    local segs = frame.top({ { 'src/a.lua', 'AzurePRPath' } }, 30, nerd)
    local s = texts(segs)
    eq(30, width(segs))
    eq('╭─ ', s:sub(1, #'╭─ '))
    eq('╮', s:sub(-#'╮'))
    local found
    for _, seg in ipairs(segs) do
      if seg[1] == 'src/a.lua' then
        found = seg[2]
      end
    end
    eq('AzurePRPath', found)
  end)

  it('truncates a long title with an ellipsis', function()
    local segs = frame.top({ { string.rep('a', 60), 'AzurePRPath' } }, 30, nerd)
    eq(30, width(segs))
    contains(texts(segs), '…')
  end)

  it('uses ascii corners', function()
    local s = texts(frame.top({ { 'x' } }, 20, ascii))
    eq('+- ', s:sub(1, 3))
    eq(20, #s)
  end)
end)

describe('frame.row', function()
  it('pads to the exact display width (wide chars)', function()
    eq(20, width(frame.row({ { 'zażółć 🙂' } }, 20, nerd)))
  end)

  it('truncates content that is too wide', function()
    local segs = frame.row({ { string.rep('x', 50) } }, 20, nerd)
    eq(20, width(segs))
    eq('│', texts(segs):sub(-#'│'))
    contains(texts(segs), '…')
  end)

  it('applies fill_hl to the padding segment', function()
    local segs = frame.row({ { 'ab' } }, 20, nerd, 'AzurePRCodeBg')
    local found = false
    for _, seg in ipairs(segs) do
      if seg[2] == 'AzurePRCodeBg' and seg[1]:match '^ +$' then
        found = true
      end
    end
    truthy(found)
  end)
end)

describe('frame.bottom / inner_width', function()
  it('draws a width-exact bottom border', function()
    local segs = frame.bottom(12, nerd)
    eq('╰──────────╯', texts(segs))
    eq(12, width(segs))
  end)

  it('inner_width is width - 4', function()
    eq(26, frame.inner_width(30))
  end)
end)

describe('frame.wrap', function()
  it('wraps on word boundaries', function()
    eq({ 'aaa bbb', 'ccc' }, frame.wrap('aaa bbb ccc', 7))
  end)

  it('hard-breaks long words', function()
    eq({ 'xxxx', 'xxxx', 'xx' }, frame.wrap(string.rep('x', 10), 4))
  end)

  it('returns one empty line for empty text', function()
    eq({ '' }, frame.wrap('', 5))
  end)
end)

describe('highlights.links (frame groups)', function()
  it('defines all new groups', function()
    for _, g in ipairs {
      'AzurePRPath', 'AzurePRBorder', 'AzurePRCodeBg', 'AzurePRCodeAdd', 'AzurePRCodeDel',
      'AzurePRCodeFocus', 'AzurePRLineNr', 'AzurePRCommentBody', 'AzurePRInlineHint', 'AzurePRInlineResolved',
    } do
      truthy(hl.links[g], g)
    end
  end)
end)
