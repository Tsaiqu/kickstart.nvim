-- Highlight groups, namespace and icon sets for azure_pr.
local M = {}

M.ns = vim.api.nvim_create_namespace 'azure_pr'

--- Highlight group -> default link target.
M.links = {
  AzurePRTitle = 'Title',
  AzurePRGroup = 'Function',
  AzurePRId = 'Number',
  AzurePRAuthor = 'Identifier',
  AzurePRBranch = 'String',
  AzurePRDraft = 'Comment',
  AzurePRApproved = 'DiagnosticOk',
  AzurePRRejected = 'DiagnosticError',
  AzurePRWaiting = 'DiagnosticWarn',
  AzurePRNoVote = 'Comment',
  AzurePRMuted = 'Comment',
  AzurePRThreadActive = 'DiagnosticWarn',
  AzurePRThreadResolved = 'DiagnosticOk',
  AzurePRCommentAuthor = 'Identifier',
  AzurePRCommentDate = 'Comment',
  AzurePRFile = 'Directory',
  AzurePRHeader = 'Title',
  AzurePRKey = 'Special',
}

local function apply()
  for group, link in pairs(M.links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

--- Define highlight groups (default links, so colorschemes/users can override) and
--- re-apply them after every colorscheme change.
function M.setup()
  apply()
  local augroup = vim.api.nvim_create_augroup('AzurePRHighlights', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', { group = augroup, callback = apply })
end

local function u(cp)
  return vim.fn.nr2char(cp)
end

-- Nerd Font codepoints (written as numbers so the file stays ASCII-safe).
local NERD = {
  approved = u(0xf00c), -- nf-fa-check
  rejected = u(0xf00d), -- nf-fa-times
  waiting = u(0xf252), -- nf-fa-hourglass_half
  no_vote = u(0xf10c), -- nf-fa-circle_o
  draft = u(0xf040), -- nf-fa-pencil
  completed = u(0xe727), -- nf-dev-git_merge
  abandoned = u(0xf05e), -- nf-fa-ban
  thread_active = u(0xf075), -- nf-fa-comment
  thread_resolved = u(0xf058), -- nf-fa-check_circle
  comment = u(0xf27b), -- nf-fa-commenting_o
  file = u(0xf15b), -- nf-fa-file
  collapsed = u(0x25b8), -- ▸
  expanded = u(0x25be), -- ▾
  user = u(0xf007), -- nf-fa-user
  -- extra (not in spec list): used by render for separators
  arrow = u(0x2192), -- →
  dot = u(0x00b7), -- ·
  ellipsis = u(0x2026), -- …
}

local ASCII = {
  approved = '+',
  rejected = 'x',
  waiting = '!',
  no_vote = 'o',
  draft = '~',
  completed = 'M',
  abandoned = '-',
  thread_active = '*',
  thread_resolved = '+', -- not 'v': that is the ascii 'expanded' fold marker
  comment = '>',
  file = '#',
  collapsed = '>',
  expanded = 'v',
  user = '@',
  arrow = '->',
  dot = '-',
  ellipsis = '~',
}

--- Icon table according to `config.icons` (nerd font when true, ascii otherwise).
---@param use_icons boolean|nil override; nil = read from config (default true)
---@return table<string, string>
function M.icons(use_icons)
  if use_icons == nil then
    use_icons = true
    local ok, config = pcall(require, 'azure_pr.config')
    if ok and type(config) == 'table' and type(config.get) == 'function' then
      local ok2, cfg = pcall(config.get)
      if ok2 and type(cfg) == 'table' and cfg.icons ~= nil then
        use_icons = cfg.icons and true or false
      end
    end
  end
  return vim.deepcopy(use_icons and NERD or ASCII)
end

return M
