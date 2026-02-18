# CLAUDE.md

## What is this?

yaks.nvim is a Neovim plugin for interacting with [Yaks](https://github.com/joelgoodman/yaks), a filesystem-native task tracker. Yaks stores tasks as plain YAML files in a `.yaks/` directory within projects — no database, no daemon. Task status is determined by which subdirectory a file lives in.

## How Yaks works

### Directory structure

```
.yaks/
  config.yaml        # project config (prefix for ID generation)
  hairy/              # tasks that need doing
  shaving/            # tasks in progress
  shorn/              # completed tasks
```

### Task YAML schema

```yaml
id: prefix-hex4       # e.g. yak-a1b2
title: string
type: bug | feature | task
priority: 1-3         # 1=highest
created: ISO8601
updated: ISO8601
depends_on: [task-ids] # optional
labels: [strings]      # optional
description: |         # optional, block scalar
  multiline text
```

### Key design decisions in Yaks

- **Status = directory.** A task's status is never stored in the YAML. Moving a file from `hairy/` to `shaving/` changes its status. This means status transitions are just file renames.
- **IDs are `{prefix}-{4 hex chars}`**, generated collision-free against existing files. The prefix comes from `config.yaml` (defaults to the project directory name).
- **Dependencies are task IDs** listed in `depends_on`. A task is "ready" (next) when all its deps are in `shorn/`. A task is "tangled" when it has at least one dep NOT in `shorn/`.
- **All data is readable YAML.** No binary formats, no database. Git history is the audit log.

### Operations (from yak.py)

| Operation | What it does |
|-----------|-------------|
| `init` | Create `.yaks/` with `hairy/`, `shaving/`, `shorn/`, and `config.yaml` |
| `create` | Create a new task YAML file in `hairy/` |
| `list` | List tasks, with optional filters (status, type, priority, label) |
| `show` | Print full YAML for a single task |
| `update` | Modify title, type, priority, description, or labels on a task |
| `shave` | Move task to `shaving/` (start working) |
| `shorn` | Move task to `shorn/` (mark complete) |
| `regrow` | Move task back to `hairy/` (reopen) |
| `next` | Show hairy tasks whose dependencies are all shorn |
| `tangled` | Show hairy tasks with at least one unshorn dependency |
| `dep add/remove` | Add or remove a dependency between two tasks |
| `stats` | Count tasks by status, type, and priority |

All operations that output data support `--json` for structured output.

### The yak.py CLI

The canonical implementation is a single Python script at `scripts/yak.py` in the yaks repo. It uses argparse with subcommands. It walks up from cwd to find `.yaks/`. All task manipulation is pure filesystem operations (read YAML, write YAML, rename files between directories).

## Architecture guidelines for this plugin

- This plugin should read `.yaks/` directly from the filesystem — it should NOT shell out to `yak.py`. The YAML format and directory conventions are the stable interface.
- Use `vim.fn.glob()`, `vim.loop` (libuv), or `vim.fs` for filesystem access.
- YAML parsing: either vendor a minimal YAML parser or use `vim.fn.system('python3 -c ...')` / `vim.json.decode` on simple structures. Since task YAML is simple (flat keys, no anchors/aliases), a line-based parser may suffice. Evaluate tradeoffs.
- Prefer Lua throughout. No Vimscript.
- Target Neovim 0.10+.
