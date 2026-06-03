return {
  'rmagatti/goto-preview',
  dependencies = { 'rmagatti/logger.nvim' },
  event = 'BufEnter',
  config = true,
  opts = {
    width = 120,
    height = 25,
    border = 'rounded',
    default_mappings = false,
  },
  keys = {
    { 'gpd', "<cmd>lua require('goto-preview').goto_preview_definition()<cr>" },
    { 'gpt', "<cmd>lua require('goto-preview').goto_preview_type_definition()<cr>" },
    { 'gpi', "<cmd>lua require('goto-preview').goto_preview_implementation()<cr>" },
    { 'gpc', "<cmd>lua require('goto-preview').close_all_win()<cr>" },
  },
}
