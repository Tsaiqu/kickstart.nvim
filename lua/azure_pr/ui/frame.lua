-- Drawing helpers for bordered comment-thread frames.
-- A Seg is { text, group|nil } (same format as `builder.add` in render.lua).
local M = {}

local function dw(s)
  return vim.fn.strdisplaywidth(s)
end

local function segs_width(segs)
  local w = 0
  for _, seg in ipairs(segs) do
    w = w + dw(seg[1])
  end
  return w
end

--- Cut segments to `max` display width; when something is dropped the last kept
--- segment ends with an ellipsis. Returns a new list.
local function truncate_segs(segs, max)
  if max <= 0 then
    return {}
  end
  if segs_width(segs) <= max then
    return vim.deepcopy(segs)
  end
  local out, used = {}, 0
  local budget = max - 1 -- room for the ellipsis
  for _, seg in ipairs(segs) do
    local w = dw(seg[1])
    if used + w <= budget then
      out[#out + 1] = { seg[1], seg[2] }
      used = used + w
    else
      local chars, cur = {}, used
      for _, ch in ipairs(vim.fn.split(seg[1], '\\zs')) do
        local cw = dw(ch)
        if cur + cw > budget then
          break
        end
        chars[#chars + 1] = ch
        cur = cur + cw
      end
      out[#out + 1] = { table.concat(chars) .. '…', seg[2] }
      return out
    end
  end
  return out
end

---@param width integer
---@return integer
function M.inner_width(width)
  return width - 4
end

--- Word-wrap by display width; a word longer than `width` is hard-broken.
---@param text string
---@param width integer
---@return string[]
function M.wrap(text, width)
  width = math.max(width, 1)
  local lines, cur, cur_w = {}, '', 0
  for word in (text or ''):gmatch '%S+' do
    local ww = dw(word)
    if cur_w > 0 and cur_w + 1 + ww <= width then
      cur = cur .. ' ' .. word
      cur_w = cur_w + 1 + ww
    else
      if cur_w > 0 then
        lines[#lines + 1] = cur
      end
      -- hard-break words wider than the line
      while dw(word) > width do
        local piece, pw = {}, 0
        for _, ch in ipairs(vim.fn.split(word, '\\zs')) do
          local cw = dw(ch)
          if pw + cw > width and pw > 0 then
            break
          end
          piece[#piece + 1] = ch
          pw = pw + cw
        end
        local head = table.concat(piece)
        lines[#lines + 1] = head
        word = word:sub(#head + 1)
      end
      cur, cur_w = word, dw(word)
    end
  end
  if cur_w > 0 or #lines == 0 then
    lines[#lines + 1] = cur
  end
  return lines
end

--- Top border: `╭─ ` title ` ─…─╮`.
---@param title_segs table[]
---@param width integer
---@param icons table<string,string>
---@return table[]
function M.top(title_segs, width, icons)
  local border = 'AzurePRBorder'
  local title = truncate_segs(title_segs, width - 6) -- "╭─ " + " " + at least one "─" + "╮"
  local fill = width - 3 - segs_width(title) - 1 - 1
  local out = { { icons.box_tl .. icons.box_h .. ' ', border } }
  vim.list_extend(out, title)
  out[#out + 1] = { ' ' .. string.rep(icons.box_h, math.max(fill, 0)) .. icons.box_tr, border }
  return out
end

--- Content row: `│ ` content (padded with `fill_hl`) ` │`.
---@param segs table[]
---@param width integer
---@param icons table<string,string>
---@param fill_hl string|nil
---@return table[]
function M.row(segs, width, icons, fill_hl)
  local border = 'AzurePRBorder'
  local inner = M.inner_width(width)
  local body = truncate_segs(segs, inner)
  local out = { { icons.box_v .. ' ', border } }
  vim.list_extend(out, body)
  local gap = inner - segs_width(body)
  if gap > 0 then
    out[#out + 1] = { string.rep(' ', gap), fill_hl }
  end
  out[#out + 1] = { ' ' .. icons.box_v, border }
  return out
end

---@param width integer
---@param icons table<string,string>
---@return table[]
function M.bottom(width, icons)
  return { { icons.box_bl .. string.rep(icons.box_h, math.max(width - 2, 0)) .. icons.box_br, 'AzurePRBorder' } }
end

return M
