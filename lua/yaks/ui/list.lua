--- Task list buffer — tabbed status view with floating help.
local fs = require("yaks.fs")
local task_mod = require("yaks.task")

local M = {}

local BUF_NAME = "yaks://list"
local ns = vim.api.nvim_create_namespace("yaks_list")

local TAB_ORDER = { "hairy", "shaving", "shorn" }
local TAB_ICONS = { hairy = "🦬", shaving = "✂️", shorn = "🐑" }

--- State for the current list buffer.
---@type {buf: integer|nil, line_map: table<integer, string>, all_entries: table[], filter_mode: string, active_tab: string, help_win: integer|nil, help_buf: integer|nil}
local state = {
  buf = nil,
  line_map = {},
  all_entries = {},
  filter_mode = "all", -- "all", "next", "tangled"
  active_tab = "hairy",
  help_win = nil,
  help_buf = nil,
}

--- Format a single task line (no status badge needed — tab provides context).
---@param entry table {status, task, path}
---@param is_tangled boolean
---@param indent_level? integer nesting depth (0 = root, default)
---@return string
local function format_task_line(entry, is_tangled, indent_level)
  local t = entry.task
  local tangled_mark = is_tangled and " [tangled]" or ""
  local indent = string.rep("  ", indent_level or 0)
  return string.format(
    "  %s%-10s p%d  %-8s %s%s",
    indent,
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
    YaksTabActive = "TabLineSel",
    YaksTabInactive = "TabLine",
    YaksFilterIndicator = "Comment",
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

--- Build the tab bar line and return segment positions for extmarks.
---@param all_entries table[]
---@param active_tab string
---@param filter_mode string
---@return string line
---@return table[] segments  {col_start, col_end, hl_group}
local function build_tab_bar(all_entries, active_tab, filter_mode)
  local st = task_mod.stats(all_entries)
  local parts = {}
  local segments = {}
  local col = 0

  for i, status in ipairs(TAB_ORDER) do
    if i > 1 then
      local sep = "   "
      parts[#parts + 1] = sep
      col = col + #sep
    end

    local count = st.by_status[status] or 0
    local icon = TAB_ICONS[status]
    local label = fs.STATUS_LABELS[status]
    local text
    if status == active_tab then
      text = string.format("[%s %s (%d)]", icon, label, count)
    else
      text = string.format(" %s %s (%d) ", icon, label, count)
    end
    parts[#parts + 1] = text
    local hl = status == active_tab and "YaksTabActive" or "YaksTabInactive"
    segments[#segments + 1] = { col_start = col, col_end = col + #text, hl_group = hl }
    col = col + #text
  end

  -- Filter indicator
  if filter_mode ~= "all" then
    local indicator
    if filter_mode == "next" then
      indicator = "  next"
    else
      indicator = "  tangled"
    end
    parts[#parts + 1] = indicator
    if active_tab ~= "hairy" then
      -- Show dimmed on non-hairy tabs
      segments[#segments + 1] = { col_start = col, col_end = col + #indicator, hl_group = "YaksFilterIndicator" }
    else
      segments[#segments + 1] = { col_start = col, col_end = col + #indicator, hl_group = "YaksHeader" }
    end
  end

  return table.concat(parts), segments
end

--- Build the buffer content lines, line_map, and extmarks.
---@param all_entries table[]
---@param active_tab string
---@param filter_mode string
---@return string[] lines
---@return table<integer, string> line_map
---@return table[] task_extmarks
---@return table[] tab_segments
local function build_content(all_entries, active_tab, filter_mode)
  local lines = {}
  local line_map = {}
  local task_extmarks = {}

  -- Tab bar header
  local tab_line, tab_segments = build_tab_bar(all_entries, active_tab, filter_mode)
  lines[#lines + 1] = tab_line
  lines[#lines + 1] = ""

  -- Determine which entries to show for the active tab
  local tab_entries = {}
  for _, e in ipairs(all_entries) do
    if e.status == active_tab then
      tab_entries[#tab_entries + 1] = e
    end
  end

  -- Apply filter only on hairy tab
  local display_entries
  if active_tab == "hairy" and filter_mode == "next" then
    display_entries = task_mod.next_tasks(all_entries)
  elseif active_tab == "hairy" and filter_mode == "tangled" then
    display_entries = task_mod.tangled_tasks(all_entries)
  else
    display_entries = tab_entries
  end

  -- Sort by priority
  task_mod.sort_by_priority(display_entries)

  -- Build tree structure: group children under parents
  local entry_by_id = {}
  for _, e in ipairs(display_entries) do
    entry_by_id[e.task.id] = e
  end

  local children_of = {}  -- parent_id → list of child entries
  local root_entries = {}  -- entries that appear at top level

  for _, e in ipairs(display_entries) do
    local pid = task_mod.parent_id(e.task.id)
    if pid and entry_by_id[pid] then
      -- Parent is in current display, group as child
      if not children_of[pid] then
        children_of[pid] = {}
      end
      children_of[pid][#children_of[pid] + 1] = e
    else
      -- Root entry (no parent, or parent in a different tab)
      root_entries[#root_entries + 1] = e
    end
  end

  -- Sort children by child number suffix
  for _, kids in pairs(children_of) do
    table.sort(kids, function(a, b)
      local a_num = tonumber(a.task.id:match("%.(%d+)$")) or 0
      local b_num = tonumber(b.task.id:match("%.(%d+)$")) or 0
      return a_num < b_num
    end)
  end

  -- Recursive render helper
  local function render_entry(entry, indent)
    local is_tangled = active_tab == "hairy" and task_mod.is_tangled(entry, all_entries)
    local task_line = format_task_line(entry, is_tangled, indent)
    lines[#lines + 1] = task_line
    line_map[#lines] = entry.task.id
    task_extmarks[#task_extmarks + 1] = { lnum = #lines - 1, entry = entry, is_tangled = is_tangled }
    -- Render children
    local kids = children_of[entry.task.id]
    if kids then
      for _, child in ipairs(kids) do
        render_entry(child, indent + 1)
      end
    end
  end

  if #display_entries == 0 then
    lines[#lines + 1] = "  (no tasks)"
    lines[#lines + 1] = ""
  else
    for _, entry in ipairs(root_entries) do
      render_entry(entry, 0)
    end
    lines[#lines + 1] = ""
  end

  -- Help footer
  lines[#lines + 1] = "Press ? for help"

  return lines, line_map, task_extmarks, tab_segments
end

--- Apply all extmark highlights to the buffer.
---@param buf integer
---@param lines string[]
---@param task_extmarks table[]
---@param tab_segments table[]
local function apply_extmarks(buf, lines, task_extmarks, tab_segments)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  -- Tab bar highlights
  for _, seg in ipairs(tab_segments) do
    vim.api.nvim_buf_set_extmark(buf, ns, 0, seg.col_start, {
      end_col = seg.col_end,
      hl_group = seg.hl_group,
    })
  end

  -- Help footer
  if #lines > 0 then
    vim.api.nvim_buf_set_extmark(buf, ns, #lines - 1, 0, {
      end_col = #lines[#lines],
      hl_group = "YaksHelp",
    })
  end

  -- Task line highlights
  for _, em in ipairs(task_extmarks) do
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

  -- Find the window showing the list buffer (may not be the current window
  -- when called from a BufWritePost in an edit split).
  local list_win = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == state.buf then
      list_win = win
      break
    end
  end

  -- Save cursor position
  local cursor_id = nil
  local cursor_row = 1
  if list_win then
    local crow = vim.api.nvim_win_get_cursor(list_win)[1]
    cursor_row = crow
    cursor_id = state.line_map[crow]
  end

  state.all_entries = fs.list_all_tasks(root)
  local lines, line_map, task_extmarks, tab_segments = build_content(state.all_entries, state.active_tab, state.filter_mode)
  state.line_map = line_map

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  apply_extmarks(state.buf, lines, task_extmarks, tab_segments)

  -- Restore cursor to same task or nearest valid position
  if list_win then
    if cursor_id then
      for lnum, id in pairs(line_map) do
        if id == cursor_id then
          pcall(vim.api.nvim_win_set_cursor, list_win, { lnum, 0 })
          return
        end
      end
    end
    -- Fallback: stay near the same row
    local max_row = vim.api.nvim_buf_line_count(state.buf)
    pcall(vim.api.nvim_win_set_cursor, list_win, { math.min(cursor_row, max_row), 0 })
  end
end

--- Cycle to the next or previous tab.
---@param direction integer 1 for next, -1 for previous
local function cycle_tab(direction)
  local idx
  for i, s in ipairs(TAB_ORDER) do
    if s == state.active_tab then
      idx = i
      break
    end
  end
  idx = ((idx - 1 + direction) % #TAB_ORDER) + 1
  state.active_tab = TAB_ORDER[idx]
  M.refresh()
  -- Move cursor to first task line (line 3, after tab bar + blank line)
  local first_task = nil
  for lnum, _ in pairs(state.line_map) do
    if not first_task or lnum < first_task then
      first_task = lnum
    end
  end
  if first_task then
    pcall(vim.api.nvim_win_set_cursor, 0, { first_task, 0 })
  end
end

--- Close the floating help window if open.
local function close_help()
  if state.help_win and vim.api.nvim_win_is_valid(state.help_win) then
    vim.api.nvim_win_close(state.help_win, true)
  end
  state.help_win = nil
  state.help_buf = nil
end

--- Open a floating help popup.
local function open_help()
  -- If already open, close it
  if state.help_win and vim.api.nvim_win_is_valid(state.help_win) then
    close_help()
    return
  end

  local help_lines = {
    " Yaks Help",
    "",
    "  Navigation",
    "  <Tab>      Next tab",
    "  <S-Tab>    Previous tab",
    "",
    "  Actions",
    "  <CR>       Show task detail",
    "  s          Shave (→ shaving)",
    "  x          Shorn (→ shorn)",
    "  r          Regrow (→ hairy)",
    "  c          Create new task",
    "  C          Create child task",
    "  e          Edit raw YAML",
    "  R          Refresh list",
    "",
    "  Filters (hairy tab only)",
    "  n          Toggle next filter",
    "  t          Toggle tangled filter",
    "  a          Show all tasks",
    "",
    "  q          Close list",
    "  ?          Toggle this help",
  }

  local width = 36
  local height = #help_lines
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local help_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, help_lines)
  vim.bo[help_buf].modifiable = false
  vim.bo[help_buf].bufhidden = "wipe"

  local help_win = vim.api.nvim_open_win(help_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    style = "minimal",
  })

  state.help_win = help_win
  state.help_buf = help_buf

  -- Highlight the title
  local help_ns = vim.api.nvim_create_namespace("yaks_help")
  vim.api.nvim_buf_set_extmark(help_buf, help_ns, 0, 0, {
    end_col = #help_lines[1],
    hl_group = "YaksHeader",
  })
  -- Highlight section headers
  local section_headers = {
    ["  Navigation"] = true,
    ["  Actions"] = true,
    ["  Filters (hairy tab only)"] = true,
  }
  for i, line in ipairs(help_lines) do
    if section_headers[line] then
      vim.api.nvim_buf_set_extmark(help_buf, help_ns, i - 1, 0, {
        end_col = #line,
        hl_group = "YaksSectionHeader",
      })
    end
  end

  -- Close on q, ?, Esc
  for _, key in ipairs({ "q", "?", "<Esc>" }) do
    vim.keymap.set("n", key, close_help, { buffer = help_buf, nowait = true })
  end

  -- Close on WinClosed
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(help_win),
    once = true,
    callback = function()
      state.help_win = nil
      state.help_buf = nil
    end,
  })
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

  map("C", function()
    local id = M.get_cursor_task_id()
    if id then
      require("yaks").create({ parent_id = id })
    end
  end, "Create child task")

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
    open_help()
  end, "Toggle help")

  map(keymaps.filter_next or "n", function()
    state.filter_mode = state.filter_mode == "next" and "all" or "next"
    if state.filter_mode == "next" then
      state.active_tab = "hairy"
    end
    M.refresh()
  end, "Toggle next filter")

  map(keymaps.filter_tangled or "t", function()
    state.filter_mode = state.filter_mode == "tangled" and "all" or "tangled"
    if state.filter_mode == "tangled" then
      state.active_tab = "hairy"
    end
    M.refresh()
  end, "Toggle tangled filter")

  map(keymaps.filter_all or "a", function()
    state.filter_mode = "all"
    M.refresh()
  end, "Show all tasks")

  -- Tab navigation
  map("<Tab>", function()
    cycle_tab(1)
  end, "Next tab")

  map("<S-Tab>", function()
    cycle_tab(-1)
  end, "Previous tab")
end

--- Set the filter mode and refresh.
---@param mode string "all", "next", or "tangled"
function M.set_filter(mode)
  state.filter_mode = mode
  if mode ~= "all" then
    state.active_tab = "hairy"
  end
  M.refresh()
end

--- Open (or focus) the task list buffer.
---@param opts? {filter?: string}
function M.open(opts)
  setup_highlights()

  local filter = opts and opts.filter
  if filter then
    state.filter_mode = filter
    state.active_tab = "hairy"
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

  -- Auto-refresh when the list buffer gains focus or vim regains focus.
  local augroup = vim.api.nvim_create_augroup("yaks_auto_refresh", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    buffer = state.buf,
    callback = function()
      M.refresh()
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = augroup,
    callback = function()
      if state.buf
        and vim.api.nvim_buf_is_valid(state.buf)
        and vim.api.nvim_get_current_buf() == state.buf
      then
        M.refresh()
      end
    end,
  })

  if not filter then
    state.filter_mode = "all"
    state.active_tab = "hairy"
  end
  M.refresh()
end

--- Close the list buffer.
function M.close()
  close_help()
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

--- Get the buffer number of the list buffer (for external use).
---@return integer|nil
function M.get_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  return nil
end

return M
