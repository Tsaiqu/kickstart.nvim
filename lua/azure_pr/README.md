# azure_pr

> **PL:** Plugin do Neovima (czysty Lua) do przeglądania pull requestów z Azure DevOps:
> lista PR-ek z filtrowaniem i grupowaniem, status (głosy recenzentów, buildy, polityki),
> wątki komentarzy oraz dodawanie komentarzy, odpowiadanie, zmiana statusu wątku i głosowanie.
> Wymaga `curl` i tokenu PAT z uprawnieniem **Code (Read & Write)**. Dalsza dokumentacja po angielsku.

Azure DevOps pull requests inside Neovim: list, filter and group PRs, see their status
and comment threads, add comments (general or on file lines), reply, edit/delete your own
comments, resolve threads and vote. Pure Lua, no Lua dependencies.

## Requirements

- Neovim >= 0.10
- `curl` in `$PATH` (all HTTP requests go through it; the PAT is never passed in argv)
- `git` (optional) - detects organization/project from the `origin` remote, finds the PR of
  the current branch, computes file paths for line comments, checks out PR branches
- An Azure DevOps Personal Access Token (PAT)

Run `:checkhealth azure_pr` to verify the setup.

## Creating a PAT

1. Open `https://dev.azure.com/<org>` and go to **User settings** (icon next to your avatar)
   > **Personal access tokens** > **New Token**.
2. Pick the organization, an expiration date and **Custom defined** scopes:
   - **Code: Read & Write** - required (PRs, threads, comments, votes).
   - Optionally **Build: Read** if you want build statuses that need it.
3. Copy the token and make it available to Neovim, in order of preference:
   - a password manager command: `pat_cmd = { 'pass', 'show', 'azure/pat' }`
   - an environment variable: `export AZURE_DEVOPS_PAT=...` (also `AZURE_DEVOPS_EXT_PAT`,
     the one used by the `az` CLI, is read)
   - `pat = '...'` in the config (discouraged - it ends up in your dotfiles)

The PAT is looked up in this order: `pat`, `pat_cmd`, `$<pat_env>`, `$AZURE_DEVOPS_EXT_PAT`.

## Setup

In this config the plugin is loaded by `lua/custom/plugins/azure_pr.lua`:

```lua
require('azure_pr').setup {
  -- everything is optional
}
return {}
```

`setup()` is cheap: it only registers `:AzurePR`, highlight groups and global keymaps.
No git or network call is made until you run a command. Calling it again is safe.

### Options (defaults)

```lua
require('azure_pr').setup {
  organization = nil,        -- 'myorg'; detected from `git remote get-url origin` when nil
  project = nil,             -- 'MyProject'; detected from the remote when nil
  repositories = nil,        -- nil = all repositories of the project, or { 'repo-a', 'repo-b' }
  base_url = 'https://dev.azure.com', -- https://myorg.visualstudio.com or on-prem https://host/tfs
  pat = nil,
  pat_env = 'AZURE_DEVOPS_PAT',
  pat_cmd = nil,             -- list (argv) or string (run with sh -c); first non-empty stdout line = PAT
  pat_cmd_timeout = 10000,   -- ms; pat_cmd runs synchronously, a failure is remembered for 5 s
  api_version = '7.1', -- on-prem: Server 2022 = '7.0', Server 2020 = '6.0' (preview endpoints follow it)
  timeout = 30,              -- seconds (curl --max-time)
  default_status = 'active', -- active | completed | abandoned | all
  max_prs = 200,             -- the list header shows `(n/200+) max_prs reached` when cut;
                             -- "mine" / "needs my vote" are also narrowed server-side
  default_group_by = 'repository', -- none | repository | author | review_state | target_branch | my_vote
  default_filters = {},      -- e.g. { draft = false }
  date_format = '%Y-%m-%d %H:%M',
  icons = true,              -- nerd-font icons; false = ASCII
  list = { layout = 'tab' }, -- tab | split | vsplit | current
  keymaps = { global = {...}, list = {...}, detail = {...} }, -- see below
}
```

Supported remotes for auto-detection: `https://[user@]dev.azure.com/org/project/_git/repo`,
`git@ssh.dev.azure.com:v3/org/project/repo`, `https://org.visualstudio.com/[DefaultCollection/]project/_git/repo`
and `org@vs-ssh.visualstudio.com:v3/org/project/repo`.

## Commands

| Command | Description |
| --- | --- |
| `:AzurePR` / `:AzurePR list [status]` | Open the PR list (`active`, `completed`, `abandoned`, `all`) |
| `:AzurePR mine` | List filtered to PRs created by me |
| `:AzurePR review` | Review queue: active, non-draft PRs where I am a reviewer and have not voted |
| `:AzurePR open [!]<id>` | Open the detail view of PR `<id>` (`!123` also works) |
| `:AzurePR current` | Detail view of the PR whose source branch is the current git branch |
| `:[range]AzurePR comment [id]` | Comment on the current line / selected lines of the file. Target PR: `id` if given, else the PR whose detail view opened the file (`<CR>` on a file thread), else the PR of the current branch, else the last opened PR detail (or a picker over the loaded PRs) |
| `:AzurePR refresh` | Refresh the detail view (when inside one) or the list |
| `:AzurePR clear_cache` | Forget cached PRs, user, PAT and detected organization/project |
| `:AzurePR health` | Same as `:checkhealth azure_pr` |

Subcommands and statuses are tab-completed. `:'<,'>AzurePR` with no subcommand also comments on the range.

## Global keymaps

Set when `keymaps.global.enabled` is true (default). `<leader>p` is used because `<leader>a`
belongs to harpoon in this config.

| Key | Action |
| --- | --- |
| `<leader>pl` | PR list |
| `<leader>pm` | My PRs |
| `<leader>pr` | Review queue |
| `<leader>pc` | PR of the current branch |
| `<leader>pa` | Comment on the current line (normal) or selected lines (visual) |

Change one with `keymaps = { global = { list = '<leader>PL' } }`, disable one with `false`,
disable all with `keymaps = { global = { enabled = false } }`. The which-key group label
("Azure [P]R") is registered for `keymaps.global.group_prefix` (default `<leader>p`); when you move
the mappings, set `group_prefix = '<leader>P'` too so the label follows them.

Line comments (`<leader>pa`, `:AzurePR comment`) use the line numbers of your local file, which
Azure reads as positions in the PR's source branch. When the PR was not found via the checked-out
branch (e.g. the file was opened from a detail view while on `main`) and HEAD is not the PR's
source branch, you are asked to confirm before the editor opens.

## PR list (`azure-pr://prs`)

| Key | Action (config name) |
| --- | --- |
| `<CR>` | Open PR detail / toggle group on a group line (`open`) |
| `za` | Toggle group fold (`toggle_group`; `<Tab>` is not mapped by default so a global `<Tab>` such as bufferline cycling keeps working) |
| `R` | Refresh (`refresh`) |
| `/`, `f` | Text filter: title, `!id`, author, repository, source branch (`text_filter`) |
| `F` | Filter menu: author, repository, target branch, draft, created by me, I'm reviewer, needs my vote, review state, clear all (`filter_menu`). A value picked from the menu matches exactly (shown as `target:=main`); a typed value is a substring match unless it starts with `=` |
| `X` | Clear filters (`clear_filters`) |
| `gb` | Group by: none / repository / author / review state / target branch / my vote (`group_by`) |
| `s` | Server-side status: active / completed / abandoned / all (`status`) |
| `m` | Toggle "created by me" (`toggle_mine`) |
| `r` | Toggle "needs my vote" (`toggle_needs_vote`) |
| `o` | Open in browser (`browser`) |
| `y` | Yank PR URL (`yank_url`) |
| `c` | New general comment (`comment`) |
| `v` | Vote (`vote`) |
| `C` | Checkout source branch, after confirmation (`checkout`) |
| `?` | Help (`help`) |
| `q` | Close (`close`) |

## PR detail (`azure-pr://pr/<id>`)

Shows title, status, author, repository, branches, merge status, reviewers with votes,
checks (build statuses and branch policies), description and comment threads with replies.

| Key | Action (config name) |
| --- | --- |
| `c` | New general comment (`comment`) |
| `r` | Reply to the thread / comment under the cursor (`reply`) |
| `e` | Edit your comment under the cursor (`edit`) |
| `d` | Delete your comment under the cursor, after confirmation (`delete`) |
| `s` | Change thread status: active, fixed, wontFix, closed, byDesign, pending (`thread_status`) |
| `t` | Show / hide resolved threads (`toggle_resolved`) |
| `za` | Fold thread (`toggle_thread`) |
| `<CR>` | Open the file of a file-anchored thread at its line (`open_file`) |
| `[t`, `]t` | Previous / next thread (`prev_thread`, `next_thread`) |
| `A` | Vote: approve, approve with suggestions, wait for author, reject, reset (`vote`) |
| `o` / `gy` | Open in browser / yank URL (`browser`, `yank_url`) |
| `R` | Refresh (`refresh`) |
| `?` / `q` | Help / close (`help`, `close`) |

`v`, `gv` and `y` are left alone in the detail view so you can select and copy comment text.

Threads anchored on the base (left) side of the diff, e.g. comments on deleted lines, are shown
as `path:12 (base)`; `<CR>` opens the file but does not jump, since the line number belongs to the
target branch version. For other file threads `<CR>` warns when the checked-out branch is not the
PR's source branch (line numbers may differ; `C` checks it out).

Every keymap value accepts a string, a list of strings, or `false`:

```lua
keymaps = {
  list = { refresh = { 'R', '<C-r>' }, checkout = false },
  detail = { delete = 'dd' },
}
```

## Comment editor

Comments are written in a floating markdown buffer. Submit with `<C-s>` (normal/insert) or
`:w` (`:wq` also works); cancel with `q` (asks "Discard comment?" when you changed the text) or
`:q`. `<Esc>` is not mapped, so leaving insert mode never throws a draft away. Empty comments are
not sent. A discarded draft is kept in the unnamed register (`""`). If sending fails (timeout,
401, network drop) the text is also put in `""`; when you are still where you submitted from, the
editor reopens with it (in normal mode) so you can retry with `<C-s>` or cancel. When you have moved
on in the meantime the editor does not pop up: the text is kept as a draft and repeating the same
action (comment / reply / edit on the same PR or thread) reopens the editor with it.

## Highlights

All groups are linked with `default = true`, so you can override them in your colorscheme:
`AzurePRTitle`, `AzurePRHeader`, `AzurePRGroup`, `AzurePRId`, `AzurePRAuthor`, `AzurePRBranch`,
`AzurePRDraft`, `AzurePRApproved`, `AzurePRRejected`, `AzurePRWaiting`, `AzurePRNoVote`,
`AzurePRMuted`, `AzurePRThreadActive`, `AzurePRThreadResolved`, `AzurePRCommentAuthor`,
`AzurePRCommentDate`, `AzurePRFile`, `AzurePRKey`.

## Troubleshooting

- **401 / 203 / sign-in page** - the PAT is missing, expired or lacks the Code scope.
- **403** - the PAT's organization or scopes don't cover the project.
- **Cannot determine organization/project** - start Neovim inside a clone of an Azure DevOps
  repository or set `organization` and `project`.
- After changing the PAT or remote, run `:AzurePR clear_cache`.

## Tests

```sh
cd ~/.config/nvim
nvim --headless --clean -u NONE -l lua/azure_pr/tests/run.lua [spec_name_substring]
```

Tests use mocked transports; they never contact Azure DevOps.
