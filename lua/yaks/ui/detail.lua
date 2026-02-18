--- Task detail view — opens in a horizontal split.
local fs = require("yaks.fs")

local M = {}

local ns = vim.api.nvim_create_namespace("yaks_detail")

--- Format a task for display in the detail buffer.
---@param entry table {status, task, path}
---@param all_entries table[] for dependency status lookup
---@return string[] lines
local function format_detail(entry, all_entries)
  local t = entry.task
  local lines = {}

  -- Build a map of task ID → status for dependency display
  local id_status = {}
  for _, e in ipairs(all_entries) do
    id_status[e.task.id] = e.status
  end

  lines[#lines + 1] = string.format("Task: %s", t.id or "???")
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("  Title:    %s", t.title or "(untitled)")
  lines[#lines + 1] = string.format("  Status:   %s", fs.STATUS_LABELS[entry.status] or entry.status)
  lines[#lines + 1] = string.format("  Type:     %s", t.type or "task")
  lines[#lines + 1] = string.format("  Priority: %d", t.priority or 0)
  lines[#lines + 1] = string.format("  Created:  %s", t.created or "")
  lines[#lines + 1] = string.format("  Updated:  %s", t.updated or "")

  -- Dependencies
  local deps = t.depends_on or {}
  if #deps > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Dependencies:"
    for _, dep_id in ipairs(deps) do
      local dep_status = id_status[dep_id] or "unknown"
      lines[#lines + 1] = string.format("    %s (%s)", dep_id, dep_status)
    end
  end

  -- Labels
  local labels = t.labels or {}
  if #labels > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("  Labels:   %s", table.concat(labels, ", "))
  end

  -- Description
  if t.description and t.description ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Description:"
    for dline in (t.description .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines + 1] = "    " .. dline
    end
    -- Remove trailing empty line from description
    if lines[#lines] == "    " then
      table.remove(lines)
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("  File: %s", entry.path)

  return lines
end

--- Apply highlights to the detail buffer.
---@param buf integer
---@param lines string[]
local function apply_highlights(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  -- Title line
  if #lines > 0 then
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      end_col = #lines[1],
      hl_group = "YaksHeader",
    })
  end

  -- Field labels
  for i, line in ipairs(lines) do
    local label_end = line:find(":%s")
    if label_end and line:match("^%s+%S+:") then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        end_col = label_end,
        hl_group = "Label",
      })
    end
  end
end

--- Set up buffer-local keymaps for the detail view.
---@param buf integer
---@param task_id string
local function setup_keymaps(buf, task_id)
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, desc = desc })
  end

  map("q", function()
    M.close(buf)
  end, "Close detail")

  map("e", function()
    M.close(buf)
    require("yaks").edit(task_id)
  end, "Edit raw YAML")

  map("s", function()
    require("yaks").shave(task_id)
    M.close(buf)
  end, "Shave task")

  map("x", function()
    require("yaks").shorn(task_id)
    M.close(buf)
  end, "Shorn task")

  map("r", function()
    require("yaks").regrow(task_id)
    M.close(buf)
  end, "Regrow task")

  map("da", function()
    vim.ui.input({ prompt = "Add dependency (task ID): " }, function(dep_id)
      if dep_id and dep_id ~= "" then
        require("yaks").dep_add(task_id, dep_id)
        -- Reopen to reflect changes
        M.close(buf)
        M.open(task_id)
      end
    end)
  end, "Add dependency")

  map("dr", function()
    local root = fs.find_root()
    if not root then
      return
    end
    local entry = fs.find_task(root, task_id)
    if not entry then
      return
    end
    local deps = entry.task.depends_on or {}
    if #deps == 0 then
      vim.notify("yaks: no dependencies to remove", vim.log.levels.INFO)
      return
    end
    vim.ui.select(deps, { prompt = "Remove dependency:" }, function(dep_id)
      if dep_id then
        require("yaks").dep_remove(task_id, dep_id)
        M.close(buf)
        M.open(task_id)
      end
    end)
  end, "Remove dependency")
end

--- Open the detail view for a task.
---@param task_id string
function M.open(task_id)
  local root = fs.find_root()
  if not root then
    vim.notify("yaks: no .yaks/ directory found", vim.log.levels.WARN)
    return
  end

  local entry = fs.find_task(root, task_id)
  if not entry then
    vim.notify("yaks: task not found: " .. task_id, vim.log.levels.ERROR)
    return
  end

  local all_entries = fs.list_all_tasks(root)
  local lines = format_detail(entry, all_entries)

  -- Open a horizontal split
  vim.cmd("split")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "yaks-detail"
  vim.api.nvim_buf_set_name(buf, "yaks://detail/" .. task_id)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  apply_highlights(buf, lines)
  setup_keymaps(buf, task_id)

  -- Resize split to fit content
  local win = vim.api.nvim_get_current_win()
  local height = math.min(#lines + 1, math.floor(vim.o.lines * 0.4))
  vim.api.nvim_win_set_height(win, height)
end

--- Close a detail buffer.
---@param buf integer
function M.close(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local wins = vim.fn.win_findbuf(buf)
    for _, win in ipairs(wins) do
      if #vim.api.nvim_list_wins() > 1 then
        vim.api.nvim_win_close(win, false)
      end
    end
  end
end

return M
