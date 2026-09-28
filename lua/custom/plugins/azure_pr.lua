-- Azure DevOps pull requests (local plugin living in lua/azure_pr).
-- The module is already on the runtimepath (config dir), so no lazy.nvim spec is needed.
-- setup() is cheap: it only registers :AzurePR, highlights and <leader>p… keymaps.
-- PAT: export AZURE_DEVOPS_PAT=... (scope "Code (Read & Write)"). See lua/azure_pr/README.md.
require('azure_pr').setup {
  -- organization = 'myorg', -- auto-detected from `git remote get-url origin` when nil
  -- project = 'MyProject',
  -- repositories = { 'repo-a', 'repo-b' },
  -- pat_cmd = { 'pass', 'show', 'azure/pat' },
}

return {}
