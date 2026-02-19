# yaks.nvim

Neovim plugin for [Yaks](https://github.com/joelgwebber/yaks), a filesystem-native task tracker. Reads and writes `.yaks/` directly — no dependency on the Python CLI.

Requires Neovim 0.10+.

## Installation

### lazy.nvim

```lua
{
  'joelgwebber/yaks.nvim',
  config = function()
    require('yaks').setup()
  end,
}
```

### Local development

```lua
{
  dir = '/path/to/yaks.nvim',
  config = function()
    require('yaks').setup()
  end,
}
```

## Usage

Run `:Yaks` in any project with a `.yaks/` directory to open the task list.

### Commands

| Command | Description |
|---------|-------------|
| `:Yaks` | Open the task list buffer |
| `:YaksNext` | Show tasks ready to shave (all deps met) |
| `:YaksTangled` | Show tasks blocked by unshorn dependencies |
| `:YaksShow {id}` | Show task details in a split |
| `:YaksShave {id}` | Move task to shaving (start work) |
| `:YaksShorn {id}` | Move task to shorn (complete) |
| `:YaksRegrow {id}` | Move task back to hairy (reopen) |
| `:YaksCreate` | Create a new task interactively |
| `:YaksEdit {id}` | Edit the raw YAML in a split |
| `:YaksUpdate {id} {field} {value}` | Update a task field |
| `:YaksDep add {id} {dep_id}` | Add a dependency |
| `:YaksDep remove {id} {dep_id}` | Remove a dependency |
| `:YaksStats` | Print task statistics |

All commands that take a task ID support tab-completion.

### List buffer keymaps

| Key | Action |
|-----|--------|
| `<CR>` | Show task detail |
| `s` | Shave (start work) |
| `x` | Shorn (complete) |
| `r` | Regrow (reopen) |
| `c` | Create new task |
| `e` | Edit raw YAML |
| `R` | Refresh |
| `n` | Toggle "next" filter |
| `t` | Toggle "tangled" filter |
| `a` | Show all tasks |
| `q` | Close |
| `?` | Toggle help |

### Detail view keymaps

| Key | Action |
|-----|--------|
| `q` | Close |
| `e` | Edit raw YAML |
| `s` / `x` / `r` | Status transitions |
| `da` | Add dependency |
| `dr` | Remove dependency |

### Statusline

Add to your statusline (lualine, heirline, etc.):

```lua
require('yaks.statusline').get()
-- Returns e.g. "Yaks: 3H 1S 2N" or "" if no .yaks/ found
```

## Configuration

All options are optional. Defaults shown:

```lua
require('yaks').setup({
  keymaps = {
    show = '<CR>',
    shave = 's',
    shorn = 'x',
    regrow = 'r',
    create = 'c',
    edit = 'e',
    refresh = 'R',
    close = 'q',
    help = '?',
    filter_next = 'n',
    filter_tangled = 't',
    filter_all = 'a',
  },
  statusline_ttl = 5, -- seconds to cache statusline data
})
```
