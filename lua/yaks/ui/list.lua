--- Task list buffer — fugitive-style scratch buffer.
local fs = require("yaks.fs")
local task_mod = require("yaks.task")

local M = {}

local BUF_NAME = "yaks://list"
local ns = vim.api.nvim_create_namespace("yaks_list")

--- State for the current list buffer.
---@type {buf: integer|nil, line_map: table<integer, string>, all_entries: table[], filter_mode: string}
local state = {
  buf = nil,
  line_map = {},
  all_entries = {},
  filter_mode = "all", -- "all", "next", "tangled"
}

--- Status badge characters.
local STATUS_BADGE = {
  hairy = "H",
  shaving = "S",
  shorn = "N",
}

--- Format a single task line.
---@param entry table {status, task, path}
---@param is_tangled boolean
---@return string
local function format_task_line(entry, is_tangled)
  local t = entry.task
  local badge = STATUS_BADGE[entry.status] or "?"
  local tangled_mark = is_tangled and " [tangled]" or ""
  return string.format(
    "  [%s] %-10s p%d  %-8s %s%s",
    badge,
    t.id or "???",
    t.priority or 0,
    t.type or "task",
    t.title or "(untitled)",
    tangled_mark
  )
end

--- Set up highlight groups.
local function setup_highlights()
  local links = {
    YaksHeader = "Title",
    YaksSectionHeader = "Label",
    YaksPriority1 = "DiagnosticError",
    YaksPriority2 = "DiagnosticWarn",
    YaksPriority3 = "DiagnosticInfo",
    YaksTaskId = "Identifier",
    YaksTangled = "DiagnosticWarn",
    YaksStatusHairy = "WarningMsg",
    YaksStatusShaving = "MoreMsg",
    YaksStatusShorn = "Comment",
    YaksHelp = "Comment",
  }
  for group, target in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
end

--- Add extmark highlights for a task line.
---@param buf integer
---@param lnum integer 0-indexed line number
---@param line string the formatted line text
---@param entry table {status, task}
---@param is_tangled boolean
local function highlight_task_line(buf, lnum, line, entry, is_tangled)
  local t = entry.task

  -- Badge highlight [H]/[S]/[N]
  local badge_start = line:find("%[") or 0
  local badge_end = line:find("%]") or 0
  if badge_start > 0 and badge_end > 0 then
    local status_hl = ({
      hairy = "YaksStatusHairy",
      shaving = "YaksStatusShaving",
      shorn = "YaksStatusShorn",
    })[entry.status] or "Normal"
    vim.api.nvim_buf_set_extmark(buf, ns, lnum, badge_start - 1, {
      end_col = badge_end,
      hl_group = status_hl,
    })
  end

  -- Task ID highlight
  local id = t.id or ""
  local id_start = line:find(id, 1, true)
  if id_start then
    vim.api.nvim_buf_set_extmark(buf, ns, lnum, id_start - 1, {
      end_col = id_start - 1 + #id,
      hl_group = "YaksTaskId",
    })
  end

  -- Priority highlight
  local p = t.priority or 0
  local p_str = "p" .. p
  local p_start = line:find(p_str, 1, true)
  if p_start then
    local p_hl = "YaksPriority" .. p
    vim.api.nvim_buf_set_extmark(buf, ns, lnum, p_start - 1, {
      end_col = p_start - 1 + #p_str,
      hl_group = p_hl,
    })
  end

  -- Tangled marker highlight
  if is_tangled then
    local tg_start = line:find("%[tangled%]")
    if tg_start then
      vim.api.nvim_buf_set_extmark(buf, ns, lnum, tg_start - 1, {
        end_col = #line,
        hl_group = "YaksTangled",
      })
    end
  end
end

--- Build the buffer content lines, line_map, and extmarks.
---@param all_entries table[]
---@param filter string "all", "next", "tangled"
---@return string[] lines
---@return table<integer, string> line_map
local function build_content(all_entries, filter)
  local lines = {}
  local line_map = {}
  local extmarks = {} -- {lnum, entry, is_tangled}

  -- Determine which entries to show
  local entries_by_status = { hairy = {}, shaving = {}, shorn = {} }
  local display_entries

  if filter == "next" then
    display_entries = task_mod.next_tasks(all_entries)
    for _, e in ipairs(display_entries) do
      table.insert(entries_by_status[e.status], e)
    end
  elseif filter == "tangled" then
    display_entries = task_mod.tangled_tasks(all_entries)
    for _, e in ipairs(display_entries) do
      table.insert(entries_by_status[e.status], e)
    end
  else
    for _, e in ipairs(all_entries) do
      table.insert(entries_by_status[e.status], e)
    end
  end

  -- Sort each group
  for _, status in ipairs(fs.STATUSES) do
    task_mod.sort_by_priority(entries_by_status[status])
  end

  -- Stats for header
  local st = task_mod.stats(all_entries)
  local filter_label = ""
  if filter == "next" then
    filter_label = " (next only)"
  elseif filter == "tangled" then
    filter_label = " (tangled only)"
  end

  -- Header line
  local header = string.format(
    "Yaks ── %d hairy · %d shaving · %d shorn%s",
    st.by_status.hairy,
    st.by_status.shaving,
    st.by_status.shorn,
    filter_label
  )
  lines[#lines + 1] = header
  lines[#lines + 1] = ""

  -- Sections
  for _, status in ipairs(fs.STATUSES) do
    local group = entries_by_status[status]
    if #group > 0 then
      local section = string.format("%s (%d)", fs.STATUS_LABELS[status], #group)
      lines[#lines + 1] = section
      local section_lnum = #lines -- 1-indexed

      for _, entry in ipairs(group) do
        local is_tangled = task_mod.is_tangled(entry, all_entries)
        local task_line = format_task_line(entry, is_tangled)
        lines[#lines + 1] = task_line
        line_map[#lines] = entry.task.id
        extmarks[#extmarks + 1] = { lnum = #lines - 1, entry = entry, is_tangled = is_tangled }
      end
      lines[#lines + 1] = ""
    end
  end

  -- Help footer
  lines[#lines + 1] = "Press ? for help"

  return lines, line_map, extmarks
end

--- Apply all extmark highlights to the buffer (must be called after buffer content is set).
---@param buf integer
---@param lines string[]
---@param extmarks table[]
local function apply_extmarks(buf, lines, extmarks)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  -- Header highlight
  if #lines > 0 then
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      end_col = #lines[1],
      hl_group = "YaksHeader",
    })
  end

  -- Section headers
  for lnum, line in ipairs(lines) do
    for _, status in ipairs(fs.STATUSES) do
      if line:match("^" .. fs.STATUS_LABELS[status] .. " %(") then
        vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
          end_col = #line,
          hl_group = "YaksSectionHeader",
        })
      end
    end
  end

  -- Help footer
  if #lines > 0 then
    vim.api.nvim_buf_set_extmark(buf, ns, #lines - 1, 0, {
      end_col = #lines[#lines],
      hl_group = "YaksHelp",
    })
  end

  -- Task line highlights
  for _, em in ipairs(extmarks) do
    highlight_task_line(buf, em.lnum, lines[em.lnum + 1], em.entry, em.is_tangled)
  end
end

--- Get the task ID under the cursor.
---@return string|nil
function M.get_cursor_task_id()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  return state.line_map[cursor[1]]
end

--- Refresh the list buffer contents.
function M.refresh()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  local root = fs.find_root()
  if not root then
    vim.notify("yaks: no .yaks/ directory found", vim.log.levels.WARN)
    return
  end

  -- Save cursor position
  local cursor_id = M.get_cursor_task_id()
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1]

  state.all_entries = fs.list_all_tasks(root)
  local lines, line_map, extmarks = build_content(state.all_entries, state.filter_mode)
  state.line_map = line_map

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  apply_extmarks(state.buf, lines, extmarks)

  -- Restore cursor to same task or nearest valid position
  if cursor_id then
    for lnum, id in pairs(line_map) do
      if id == cursor_id then
        pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
        return
      end
    end
  end
  -- Fallback: stay near the same row
  local max_row = vim.api.nvim_buf_line_count(state.buf)
  pcall(vim.api.nvim_win_set_cursor, 0, { math.min(cursor_row, max_row), 0 })
end

--- Set up buffer-local keymaps.
---@param buf integer
local function setup_keymaps(buf)
  local config = require("yaks").config
  local keymaps = config.keymaps or {}

  local function map(key, fn, desc)
    if key then
      vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, desc = desc })
    end
  end

  map(keymaps.show or "<CR>", function()
    local id = M.get_cursor_task_id()
    if id then
      require("yaks.ui.detail").open(id)
    end
  end, "Show task detail")

  map(keymaps.shave or "s", function()
    local id = M.get_cursor_task_id()
    if id then
      require("yaks").shave(id)
    end
  end, "Shave task (→ shaving)")

  map(keymaps.shorn or "x", function()
    local id = M.get_cursor_task_id()
    if id then
      require("yaks").shorn(id)
    end
  end, "Shorn task (→ shorn)")

  map(keymaps.regrow or "r", function()
    local id = M.get_cursor_task_id()
    if id then
      require("yaks").regrow(id)
    end
  end, "Regrow task (→ hairy)")

  map(keymaps.create or "c", function()
    require("yaks").create()
  end, "Create task")

  map(keymaps.edit or "e", function()
    local id = M.get_cursor_task_id()
    if id then
      require("yaks").edit(id)
    end
  end, "Edit raw YAML")

  map(keymaps.refresh or "R", function()
    M.refresh()
  end, "Refresh list")

  map(keymaps.close or "q", function()
    M.close()
  end, "Close list")

  map(keymaps.help or "?", function()
    M.toggle_help()
  end, "Toggle help")

  map(keymaps.filter_next or "n", function()
    state.filter_mode = state.filter_mode == "next" and "all" or "next"
    M.refresh()
  end, "Toggle next filter")

  map(keymaps.filter_tangled or "t", function()
    state.filter_mode = state.filter_mode == "tangled" and "all" or "tangled"
    M.refresh()
  end, "Toggle tangled filter")

  map(keymaps.filter_all or "a", function()
    state.filter_mode = "all"
    M.refresh()
  end, "Show all tasks")
end

--- Set the filter mode and refresh.
---@param mode string "all", "next", or "tangled"
function M.set_filter(mode)
  state.filter_mode = mode
  M.refresh()
end

--- Open (or focus) the task list buffer.
---@param opts? {filter?: string}
function M.open(opts)
  setup_highlights()

  local filter = opts and opts.filter
  if filter then
    state.filter_mode = filter
  end

  -- Reuse existing buffer if valid
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    -- Find or create a window for it
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == state.buf then
        vim.api.nvim_set_current_win(win)
        M.refresh()
        return
      end
    end
    vim.api.nvim_set_current_buf(state.buf)
    M.refresh()
    return
  end

  -- Create the buffer
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(state.buf, BUF_NAME)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "yaks"

  -- Show in current window
  vim.api.nvim_set_current_buf(state.buf)

  setup_keymaps(state.buf)
  if not filter then
    state.filter_mode = "all"
  end
  M.refresh()
end

--- Close the list buffer.
function M.close()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    -- Find windows showing this buffer and close them or switch to alternate
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == state.buf then
        if #vim.api.nvim_list_wins() > 1 then
          vim.api.nvim_win_close(win, false)
        else
          -- Last window, switch to alternate or empty buffer
          local alt = vim.fn.bufnr("#")
          if alt > 0 and alt ~= state.buf and vim.api.nvim_buf_is_valid(alt) then
            vim.api.nvim_win_set_buf(win, alt)
          else
            vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
          end
        end
      end
    end
  end
end

--- Toggle help text at the bottom of the list.
function M.toggle_help()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  local last_line = vim.api.nvim_buf_get_lines(state.buf, -2, -1, false)[1] or ""

  vim.bo[state.buf].modifiable = true
  if last_line:match("^%s+%S+ ") then
    -- Help is showing, remove it
    -- Find where help starts
    local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
    local help_start = nil
    for i = #lines, 1, -1 do
      if lines[i] == "Press ? for help" or lines[i] == "" then
        break
      end
      if lines[i]:match("^%s+%S+ ") then
        help_start = i
      end
    end
    if help_start then
      vim.api.nvim_buf_set_lines(state.buf, help_start - 1, -1, false, { "Press ? for help" })
    end
  else
    -- Show help
    local help_lines = {
      "",
      "  <CR>  Show task detail",
      "  s     Shave (→ shaving)",
      "  x     Shorn (→ shorn)",
      "  r     Regrow (→ hairy)",
      "  c     Create new task",
      "  e     Edit raw YAML",
      "  R     Refresh list",
      "  n     Toggle next filter",
      "  t     Toggle tangled filter",
      "  a     Show all tasks",
      "  q     Close",
    }
    -- Replace the "Press ? for help" line
    local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
    for i = #lines, 1, -1 do
      if lines[i] == "Press ? for help" then
        vim.api.nvim_buf_set_lines(state.buf, i - 1, i, false, help_lines)
        break
      end
    end
  end
  vim.bo[state.buf].modifiable = false
end

--- Get the buffer number of the list buffer (for external use).
---@return integer|nil
function M.get_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  return nil
end

return M
