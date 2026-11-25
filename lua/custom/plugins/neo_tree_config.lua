local function focus_next_directory(state, reverse)
  local win = state.winid
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  local current = vim.api.nvim_win_get_cursor(win)[1]
  local step = reverse and -1 or 1
  for i = 1, count - 1 do
    local line = (current - 1 + i * step) % count + 1
    local node = state.tree:get_node(line)
    if node and node.type == 'directory' and not (node.filtered_by and node.filtered_by.gitignored) then
      vim.api.nvim_win_set_cursor(win, { line, 0 })
      return
    end
  end
end

local function focus_next_git_changed(state, reverse)
  local utils = require 'neo-tree.utils'
  local uv = vim.uv or vim.loop
  local node = state.tree:get_node()
  if not node then
    return
  end
  local current_path = node:get_id()
  local git = require 'neo-tree.git'
  local _, worktree_info = git.find_existing_worktree(current_path)
  worktree_info = worktree_info or git.worktrees[current_path]
  if not utils.truthy(worktree_info) then
    return
  end

  local function is_dir(path)
    local stat = uv.fs_stat(path)
    return stat ~= nil and stat.type == 'directory'
  end

  local paths, seen = { current_path }, { [current_path] = true }
  local function add(path)
    if not seen[path] and utils.is_subpath(state.path, path) then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  for path, status in pairs(worktree_info.status) do
    path = path:gsub('/+$', '')
    if status ~= '!' then
      if status == '?' and is_dir(path) then
        for name, type in vim.fs.dir(path, { depth = math.huge }) do
          if type == 'file' then
            add(path .. '/' .. name)
          end
        end
      else
        add(path)
      end
    end
  end

  local sorted = utils.sort_by_tree_display(paths)
  local from, to, step = 1, #sorted, 1
  if reverse then
    from, to, step = #sorted, 1, -1
  end
  local passed, target = false, nil
  for i = from, to, step do
    local path = sorted[i]
    local file = not is_dir(path)
    if target == nil and file then
      target = path
    end
    if passed and file then
      target = path
      break
    elseif path == current_path then
      passed = true
    end
  end
  if not target then
    return
  end

  if state.tree:get_node(target) then
    require('neo-tree.ui.renderer').focus_node(state, target)
  else
    require('neo-tree.sources.filesystem').navigate(state, state.path, target, nil, false)
  end
end

return {
  'nvim-neo-tree/neo-tree.nvim',
  version = '*',
  lazy = false,
  dependencies = {
    'nvim-lua/plenary.nvim',
    'nvim-tree/nvim-web-devicons',
    'MunifTanjim/nui.nvim',
    'luckasRanarison/neo-rename.nvim',
  },
  keys = {
    { '\\', ':Neotree toggle<CR>', desc = 'NeoTree toggle' },
    --[[ {
      '\\',
      function()
        local neo_tree_open = #vim.tbl_filter(function(win)
          return vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'neo-tree'
        end, vim.api.nvim_list_wins()) > 0

        if neo_tree_open then
          require('neo-tree.command').execute { action = 'close' }
        else
          require('neo-tree.command').execute {
            action = 'show',
            dir = vim.fn.getcwd(),
          }
        end
      end,
    }, ]]
    --[[ {
      '\\',
      function()
        -- Never let neo-tree prompt to change cwd when the current buffer
        -- lives outside it; just reveal within the existing cwd if possible.
        require('neo-tree.command').execute {
          action = 'focus',
          reveal = true,
          dir = vim.fn.getcwd(),
        }
      end,
      desc = 'NeoTree reveal',
      silent = true,
    }, ]]
  },
  init = function()
    -- `:q` / `:wq` typed in the (non-floating) neo-tree window quits Neovim instead of only closing
    -- the tree. Like `:q` in the last window, `qa` refuses (E37) while buffers have unsaved changes.
    vim.api.nvim_create_autocmd('QuitPre', {
      group = vim.api.nvim_create_augroup('NeoTreeQuitAll', { clear = true }),
      callback = function()
        local win = vim.api.nvim_get_current_win()
        if vim.bo[vim.api.nvim_win_get_buf(win)].filetype ~= 'neo-tree' or vim.api.nvim_win_get_config(win).relative ~= '' then
          return
        end
        vim.schedule(function()
          local ok, err = pcall(vim.cmd, 'qa')
          if not ok then
            vim.notify(tostring(err):gsub('^Vim%(%a+%):', ''), vim.log.levels.ERROR)
          end
        end)
      end,
    })
  end,
  opts = {
    auto_close = true,
    auto_open = false,
    auto_update = true,
    update_to_buf_dir = true,
    close_if_last_window = true,
    popup_border_style = '',
    source_selector = { winbar = true, statusline = false },
    clipboard = {
      sync = 'universal',
    },
    enable_git_status = true,
    enable_diagnostics = true,
    open_files_do_not_replace_types = { 'terminal', 'trouble', 'qf' },
    open_files_using_relative_paths = false,
    sort_case_insensitive = false,
    sort_function = nil,
    -- sort_function = function(a, b)
    --   if a.type == b.type then
    --     return a.path > b.path
    --   else
    --     return a.type > b.type
    --   end
    -- end, -- this sorts files and directories descendantly
    event_handlers = {
      {
        event = 'after_render',
        handler = function(state)
          if not require 'neo-tree.sources.common.preview' then
            state.config = { use_float = true }
            state.commands.toggle_preview(state)
          end
        end,
      },
    },
    default_component_configs = {
      container = {
        enable_character_fade = true,
      },
      indent = {
        indent_size = 2,
        padding = 1, -- extra padding on left hand side
        -- indent guides
        with_markers = true,
        indent_marker = '│',
        last_indent_marker = '└',
        highlight = 'NeoTreeIndentMarker',
        -- expander config, needed for nesting files
        with_expanders = nil, -- if nil and file nesting is enable, will enable expanders
        expander_collapsed = '',
        expander_expanded = '',
        expander_highlight = 'NeoTreeExpander',
      },
      icon = {
        -- folder_closed = '',
        -- folder_open = '',
        folder_empty = '󰜌',
        provider = function(icon, node, state) -- deafult icon provider utilizes nvim-web-devicons if available
          if node.type == 'file' or node.type == 'terminal' then
            local success, web_devicons = pcall(require, 'nvim-web-devicons')
            local name = node.type == 'terminal' and 'terminal' or node.name
            if success then
              local devicon, hl = web_devicons.get_icon(name)
              icon.text = devicon or icon.text
              icon.highlight = hl or icon.highlight
            end
          end
        end,
        -- The next two settings are only a fallback, if you use nvim-web-devicons and configure default icons there
        -- then these will never be used.
        default = '*',
        highlight = 'NeoTreeFileIcon',
        use_filtered_colors = true, -- Whether to use a different highlight when the file is filtered (hidden, dotfile, etc.).
      },
      modified = {
        symbol = '[+]',
        highlight = 'NeoTreeModified',
      },
      name = {
        trailing_slash = false,
        use_filtered_colors = true, -- same as above
        use_git_status_colors = true,
        highlight = 'NeoTreeFileName',
      },
      git_status = {
        symbols = {
          added = '+',
          modified = '',
          deleted = '✖',
          renamed = '󰁕',
          -- Status type
          untracked = '',
          ignored = '',
          unstaged = '󰄱',
          staged = '',
          conflict = '',
        },
      },
      -- If you don't want to use these columns, you can set `enabled = false` for each of them individually
      file_size = {
        enabled = true,
        width = 12, -- width of the column
        required_width = 64, -- min width of window required to show this column
      },
      type = {
        enabled = true,
        width = 10, -- width of the column
        required_width = 122, -- min width of window required to show this column
      },
      last_modified = {
        enabled = true,
        width = 20, -- width of the column
        required_width = 88, -- min width of window required to show this column
      },
      created = {
        enabled = true,
        width = 20, -- width of the column
        required_width = 110, -- min width of window required to show this column
      },
      symlink_target = {
        enabled = false,
      },
    },
    -- A list of functions, each representing a global custom command
    -- that will be available in all sources (if not overridden in `opts[source_name].commands`)
    -- see `:h neo-tree-custom-commands-global`
    commands = {},
    window = {
      position = 'right',
      width = 40,
      mapping_options = {
        noremap = true,
        nowait = true,
      },
      mappings = {
        ['<space>'] = {
          'toggle_node',
          nowait = false, -- disable `nowait` if you have existing combos starting with this char that you want to use
        },
        ['<2-LeftMouse>'] = 'open',
        ['<cr>'] = 'open',
        ['<esc>'] = 'cancel', -- close preview or floating neo-tree window
        ['P'] = {
          'toggle_preview',
          config = {
            use_float = true,
            use_snacks_image = true,
            use_image_nvim = true,
          },
        },
        -- Read `# Preview Mode` for more information
        ['l'] = 'focus_preview',
        ['S'] = 'open_split',
        ['s'] = 'open_vsplit',
        -- ["S"] = "split_with_window_picker",
        -- ["s"] = "vsplit_with_window_picker",
        ['t'] = 'open_tabnew',
        -- ["<cr>"] = "open_drop",
        -- ["t"] = "open_tab_drop",
        ['w'] = 'open_with_window_picker',
        --["P"] = "toggle_preview", -- enter preview mode, which shows the current node without focusing
        ['C'] = 'close_node',
        -- ['C'] = 'close_all_subnodes',
        ['z'] = 'close_all_nodes',
        --["Z"] = "expand_all_nodes",
        --["Z"] = "expand_all_subnodes",
        ['a'] = {
          'add',
          -- this command supports BASH style brace expansion ("x{a,b,c}" -> xa,xb,xc). see `:h neo-tree-file-actions` for details
          -- some commands may take optional config options, see `:h neo-tree-mappings` for details
          config = {
            show_path = 'none', -- "none", "relative", "absolute"
          },
        },
        ['A'] = 'add_directory', -- also accepts the optional config.show_path option like "add". this also supports BASH style brace expansion.
        ['d'] = 'delete',
        ['r'] = 'rename',
        ['b'] = 'rename_basename',
        ['y'] = 'copy_to_clipboard',
        ['x'] = 'cut_to_clipboard',
        ['p'] = 'paste_from_clipboard',
        ['<C-r>'] = 'clear_clipboard',
        ['c'] = 'copy', -- takes text input for destination, also accepts the optional config.show_path option like "add":
        -- ["c"] = {
        --  "copy",
        --  config = {
        --    show_path = "none" -- "none", "relative", "absolute"
        --  }
        --}
        ['m'] = 'move', -- takes text input for destination, also accepts the optional config.show_path option like "add".
        ['q'] = 'close_window',
        ['\\'] = 'close_window',
        ['R'] = 'refresh',
        ['?'] = 'show_help',
        ['<'] = 'prev_source',
        ['>'] = 'next_source',
        ['i'] = 'show_file_details',
        -- ["i"] = {
        --   "show_file_details",
        --   -- format strings of the timestamps shown for date created and last modified (see `:h os.date()`)
        --   -- both options accept a string or a function that takes in the date in seconds and returns a string to display
        --   -- config = {
        --   --   created_format = "%Y-%m-%d %I:%M %p",
        --   --   modified_format = "relative", -- equivalent to the line below
        --   --   modified_format = function(seconds) return require('neo-tree.utils').relative_date(seconds) end
        --   -- }
        -- },
      },
    },
    nesting_rules = {},
    filesystem = {
      -- Deep search (`/`, `f`) uses fd. Without --hidden fd skips dot-dirs (e.g. `.config`),
      -- so files nested inside them were never found.
      search_limit = 200,
      find_args = function(cmd, _, _, args)
        if cmd ~= 'fd' then
          return args
        end
        table.insert(args, '--hidden')
        for _, dir in ipairs { '.git', 'node_modules', '.venv', '__pycache__', '.mypy_cache', '.pytest_cache' } do
          table.insert(args, '--exclude')
          table.insert(args, dir)
        end
        return args
      end,
      filtered_items = {
        visible = false, -- when true, they will just be displayed differently than normal items
        show_hidden_count = false, -- don't show "(x hidden items)" placeholder line
        hide_dotfiles = true,
        hide_gitignored = true,
        hide_ignored = true, -- hide files that are ignored by other gitignore-like files
        -- other gitignore-like files, in descending order of precedence.
        ignore_files = {
          '.neotreeignore',
          '.ignore',
          -- ".rgignore"
        },
        hide_hidden = true, -- only works on Windows for hidden files/directories
        hide_by_name = {
          --"node_modules"
        },
        hide_by_pattern = { -- uses glob style patterns
          --"*.meta",
          --"*/src/*/tsconfig.json",
        },
        always_show = { -- remains visible even if other settings would normally hide it
          --".gitignored",
        },
        always_show_by_pattern = { -- uses glob style patterns
          --".env*",
        },
        never_show = { -- remains hidden even if visible is toggled to true, this overrides always_show
          --".DS_Store",
          --"thumbs.db"
        },
        never_show_by_pattern = { -- uses glob style patterns
          --".null-ls_*",
        },
      },
      follow_current_file = {
        enabled = true, -- This will find and focus the file in the active buffer every time
        --               -- the current file is changed while the tree is open.
        leave_dirs_open = false, -- `false` closes auto expanded dirs, such as with `:Neotree reveal`
      },
      group_empty_dirs = false, -- when true, empty folders will be grouped together
      hijack_netrw_behavior = 'open_default', -- netrw disabled, opening a directory opens neo-tree
      -- in whatever position is specified in window.position
      -- "open_current",  -- netrw disabled, opening a directory opens within the
      -- window like netrw would, regardless of window.position
      -- "disabled",    -- netrw left alone, neo-tree does not handle opening dirs
      use_libuv_file_watcher = true, -- This will use the OS level file watchers to detect changes
      -- instead of relying on nvim autocmd events.
      -- Needed so git status (added/modified/etc.) refreshes when git commands
      -- (add/commit/push) run outside of Neovim's own buffer-write events.
      window = {
        mappings = {
          ['<bs>'] = 'navigate_up',
          [','] = 'set_root',
          ['.'] = 'toggle_hidden',
          ['/'] = 'fuzzy_finder',
          ['D'] = 'fuzzy_finder_directory',
          ['#'] = 'fuzzy_sorter', -- fuzzy sorting using the fzy algorithm
          -- ["D"] = "fuzzy_sorter_directory",
          ['f'] = 'filter_on_submit',
          ['<c-x>'] = 'clear_filter',
          ['[g'] = 'prev_git_changed',
          [']g'] = 'next_git_changed',
          ['<Tab>'] = 'next_directory',
          ['<S-Tab>'] = 'prev_directory',
          ['o'] = {
            'show_help',
            nowait = false,
            config = { title = 'Order by', prefix_key = 'o' },
          },
          ['oc'] = { 'order_by_created', nowait = false },
          ['od'] = { 'order_by_diagnostics', nowait = false },
          ['og'] = { 'order_by_git_status', nowait = false },
          ['om'] = { 'order_by_modified', nowait = false },
          ['on'] = { 'order_by_name', nowait = false },
          ['os'] = { 'order_by_size', nowait = false },
          ['ot'] = { 'order_by_type', nowait = false },
          -- ['<key>'] = function(state) ... end,
          ['O'] = 'system_open',
        },
        fuzzy_finder_mappings = { -- define keymaps for filter popup window in fuzzy_finder_mode
          ['<down>'] = 'move_cursor_down',
          ['<C-n>'] = 'move_cursor_down',
          ['<up>'] = 'move_cursor_up',
          ['<C-p>'] = 'move_cursor_up',
          ['<esc>'] = 'close',
          ['<S-CR>'] = 'close_keep_filter',
          ['<C-CR>'] = 'close_clear_filter',
          ['<C-w>'] = { '<C-S-w>', raw = true },
          {
            -- normal mode mappings
            n = {
              ['j'] = 'move_cursor_down',
              ['k'] = 'move_cursor_up',
              ['<S-CR>'] = 'close_keep_filter',
              ['<C-CR>'] = 'close_clear_filter',
              ['<esc>'] = 'close',
            },
          },
          -- ["<esc>"] = "noop", -- if you want to use normal mode
          -- ["key"] = function(state, scroll_padding) ... end,
        },
      },

      commands = {
        next_directory = function(state)
          focus_next_directory(state, false)
        end,
        prev_directory = function(state)
          focus_next_directory(state, true)
        end,
        next_git_changed = function(state)
          focus_next_git_changed(state, false)
        end,
        prev_git_changed = function(state)
          focus_next_git_changed(state, true)
        end,
        system_open = function(state)
          local node = state.tree:get_node()
          local path = node:get_id()
          vim.fn.jobstart({ 'xdg-open', path }, { detach = true })
        end,
      }, -- Add a custom command or override a global one using the same function name
    },
    buffers = {
      follow_current_file = {
        enabled = true, -- This will find and focus the file in the active buffer every time
        --              -- the current file is changed while the tree is open.
        leave_dirs_open = false, -- `false` closes auto expanded dirs, such as with `:Neotree reveal`
      },
      group_empty_dirs = true, -- when true, empty folders will be grouped together
      show_unloaded = true,
      window = {
        mappings = {
          ['d'] = 'buffer_delete',
          ['bd'] = 'buffer_delete',
          ['<bs>'] = 'navigate_up',
          ['.'] = 'set_root',
          ['o'] = {
            'show_help',
            nowait = false,
            config = { title = 'Order by', prefix_key = 'o' },
          },
          ['oc'] = { 'order_by_created', nowait = false },
          ['od'] = { 'order_by_diagnostics', nowait = false },
          ['om'] = { 'order_by_modified', nowait = false },
          ['on'] = { 'order_by_name', nowait = false },
          ['os'] = { 'order_by_size', nowait = false },
          ['ot'] = { 'order_by_type', nowait = false },
        },
      },
    },
    git_status = {
      window = {
        position = 'float',
        mappings = {
          ['A'] = 'git_add_all',
          ['gu'] = 'git_unstage_file',
          ['gU'] = 'git_undo_last_commit',
          ['ga'] = 'git_add_file',
          ['gt'] = 'git_toggle_file_stage',
          ['gr'] = 'git_revert_file',
          ['gc'] = 'git_commit',
          ['gp'] = 'git_push',
          ['gg'] = 'git_commit_and_push',
          ['o'] = {
            'show_help',
            nowait = false,
            config = { title = 'Order by', prefix_key = 'o' },
          },
          ['oc'] = { 'order_by_created', nowait = false },
          ['od'] = { 'order_by_diagnostics', nowait = false },
          ['om'] = { 'order_by_modified', nowait = false },
          ['on'] = { 'order_by_name', nowait = false },
          ['os'] = { 'order_by_size', nowait = false },
          ['ot'] = { 'order_by_type', nowait = false },
        },
      },
    },
  },
}
