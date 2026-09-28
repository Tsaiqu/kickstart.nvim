-- Shared in-memory store for azure_pr (reset with M.reset()).
local M = {}

---Reset every field to its initial value (keeps the same table so `require` references stay valid).
function M.reset()
  M.prs = {} ---@type AzurePR[] last fetched (normalized) list
  M.user = nil ---@type {id:string, name:string, unique_name:string}|nil
  M.filters = {} ---@type AzurePRFilters
  M.group_by = nil ---@type string|nil
  M.status = nil ---@type string|nil last server-side status filter
  M.collapsed = {} ---@type table<string, boolean> group key -> collapsed
  M.drafts = {} ---@type table<string, string> editor title -> comment text whose send failed
  M.review_pr = nil ---@type AzurePR|nil PR of the most recently opened/used detail view (line comment fallback)
end

M.reset()

return M
