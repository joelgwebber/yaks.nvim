# yaks.nvim — Design Plan

## Goals

A Neovim plugin that gives you native access to Yaks task data without leaving your editor. Read and manipulate `.yaks/` task files directly from the filesystem — no dependency on the Python CLI.

## Open questions

### Scope — what should v0.1 do?

Possible feature tiers:

**Tier 1 — Read-only visibility**
- `:Yaks` or `:YaksList` — open a buffer/window showing all tasks grouped by status
- `:YaksNext` — show only tasks ready to shave
- `:YaksShow {id}` — show full task detail in a preview/floating window
- Statusline component (count of hairy/shaving tasks)

**Tier 2 — Status transitions**
- `:YaksShave {id}` — move to shaving (file rename)
- `:YaksShorn {id}` — move to shorn
- `:YaksRegrow {id}` — move back to hairy
- Keymaps in the list buffer to transition tasks under cursor

**Tier 3 — Full CRUD**
- `:YaksCreate` — interactive task creation (prompt for title, type, priority)
- `:YaksUpdate {id}` — edit fields
- `:YaksDep add/remove` — dependency management
- Open task YAML in a buffer for direct editing

**Tier 4 — Rich UI**
- Telescope/fzf-lua picker for tasks
- Signs/virtual text in the list buffer (priority colors, dependency indicators)
- Task preview on hover in Telescope
- Auto-refresh on filesystem changes (fswatch / vim.loop.fs_event)

### UI paradigm

Options to discuss:
1. **Scratch buffer** — like fugitive's `:Git` summary. A plain text buffer with syntax highlighting and keymaps. Simple, composable, familiar.
2. **Floating window** — modal popup with task list. More "app-like" but less vim-native.
3. **Telescope/picker** — tasks as picker entries. Great for selection, less good for overview.
4. **Split** — dedicated side panel (like nvim-tree). Persistent but uses screen space.

These aren't mutually exclusive — a scratch buffer for the list + Telescope for fuzzy finding is a common pattern.

### YAML parsing

Task YAML is intentionally simple — flat string/int/list-of-strings keys, no anchors, no flow mappings. Options:
1. **Minimal Lua parser** — parse the limited subset we need. ~50-100 lines. No external deps. Fragile if schema grows.
2. **lyaml** (luarocks) — full YAML parser. Correct but adds a dependency.
3. **Shell out to Python/yq** — guaranteed correct, but slow and adds runtime deps.
4. **Treat YAML as line-based text** — since we know the schema, just regex the lines. Fastest, most fragile.

Recommendation: start with a minimal Lua parser that handles the known schema. If it becomes a maintenance burden, switch to lyaml.

### YAML writing

For status transitions (shave/shorn/regrow), we need to:
1. Rename the file to a different directory
2. Update the `updated:` timestamp in the YAML

Option A: Read the file, parse, modify `updated`, serialize, write. Requires a YAML writer.
Option B: Read the file as text, regex-replace the `updated:` line, write. Simple but brittle.
Option C: Just rename the file and don't update the timestamp. Simplest but diverges from CLI behavior.

### Integration points

- **Telescope** — optional integration if telescope is installed
- **Which-key** — register descriptions for keymaps
- **Lualine/heirline** — statusline component
- **nvim-web-devicons** — icons for task types?

## Proposed module structure

```
lua/
  yaks/
    init.lua          # setup(), config, commands
    fs.lua            # find .yaks/ root, read/write task files
    parser.lua        # YAML parsing (task schema subset)
    task.lua          # task data model, filtering, sorting
    ui/
      list.lua        # scratch buffer for task list
      detail.lua      # task detail view
    telescope.lua     # optional telescope picker
    statusline.lua    # statusline component
plugin/
  yaks.lua            # auto-setup, define user commands
```

## Setup API

```lua
require('yaks').setup({
  -- auto-detect .yaks/ from cwd (default true)
  auto_detect = true,

  -- keymaps in the list buffer
  keymaps = {
    shave = 's',
    shorn = 'x',
    regrow = 'r',
    show = '<CR>',
    refresh = 'R',
  },

  -- optional integrations
  telescope = true,   -- register telescope extension if available
  statusline = true,  -- enable statusline component
})
```
