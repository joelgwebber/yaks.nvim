--- yaks.nvim — Neovim plugin for the Yaks filesystem-native task tracker.
local M = {}

--- Default configuration.
M.config = {
  keymaps = {
    show = "<CR>",
    shave = "s",
    shorn = "x",
    regrow = "r",
    create = "c",
    edit = "e",
    refresh = "R",
    close = "q",
    help = "?",
    filter_next = "n",
    filter_tangled = "t",
    filter_all = "a",
  },
  split = "vertical",
  list_size = nil, -- nil = auto (60 for vertical, 20 for horizontal)
  statusline_ttl = 5,
}

--- Return the split command based on config (for the list window direction).
---@return string
function M.split_cmd()
  return M.config.split == "vertical" and "vsplit" or "split"
end

--- Return the cross-axis split command (opposite of the list direction).
-- Detail, edit, and create windows open perpendicular to the list.
-- Uses the effective list split direction if available, falling back to config.
---@return string
function M.cross_split_cmd()
  local list_split = require("yaks.ui.list").get_split()
  local split = list_split or M.config.split or "vertical"
  return split == "vertical" and "split" or "vsplit"
end

--- Set up the plugin with user configuration.
---@param opts? table
function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", M.config, opts)
end

-- ── Commands ──────────────────────────────────────────────────────

--- Open the task list buffer.
---@param opts? {split?: string}
function M.list(opts)
  require("yaks.ui.list").open(opts)
end

--- Open the task list filtered to "next" tasks.
function M.next()
  require("yaks.ui.list").open({ filter = "next" })
end

--- Open the task list filtered to "tangled" tasks.
function M.tangled()
  require("yaks.ui.list").open({ filter = "tangled" })
end

--- Show full details for a task.
---@param id string task ID
function M.show(id)
  require("yaks.ui.detail").open(id)
end

--- Move a task to shaving.
---@param id string task ID
function M.shave(id)
  local fs = require("yaks.fs")
  local root = fs.find_root()
  if not root then
    vim.notify("yaks: no .yaks/ directory found", vim.log.levels.WARN)
    return
  end
  local ok, err = fs.move_task(root, id, "shaving")
  if not ok then
    vim.notify("yaks: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return
  end
  vim.notify("yaks: " .. id .. " → shaving", vim.log.levels.INFO)
  M._post_write()
end

--- Move a task to shorn.
---@param id string task ID
function M.shorn(id)
  local fs = require("yaks.fs")
  local root = fs.find_root()
  if not root then
    vim.notify("yaks: no .yaks/ directory found", vim.log.levels.WARN)
    return
  end
  local ok, err = fs.move_task(root, id, "shorn")
  if not ok then
    vim.notify("yaks: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return
  end
  vim.notify("yaks: " .. id .. " → shorn", vim.log.levels.INFO)
  M._post_write()
end

--- Move a task back to hairy.
---@param id string task ID
function M.regrow(id)
  local fs = require("yaks.fs")
  local root = fs.find_root()
  if not root then
    vim.notify("yaks: no .yaks/ directory found", vim.log.levels.WARN)
    return
  end
  local ok, err = fs.move_task(root, id, "hairy")
  if not ok then
    vim.notify("yaks: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return
  end
  vim.notify("yaks: " .. id .. " → hairy", vim.log.levels.INFO)
  M._post_write()
end

--- Create a new task interactively.
---@param opts? {parent_id?: string}
function M.create(opts)
  opts = opts or {}
  local fs = require("yaks.fs")
  local task_mod = require("yaks.task")

  local root = fs.find_root()
  if not root then
    vim.notify("yaks: no .yaks/ directory found", vim.log.levels.WARN)
    return
  end

  -- If creating a child task, verify parent exists and generate child ID
  local parent_id = opts.parent_id
  if parent_id then
    local parent_entry = fs.find_task(root, parent_id)
    if not parent_entry then
      vim.notify("yaks: parent task not found: " .. parent_id, vim.log.levels.ERROR)
      return
    end
  end

  vim.ui.input({ prompt = "Task title: " }, function(title)
    if not title or title == "" then
      return
    end

    vim.ui.select({ "task", "bug", "feature" }, { prompt = "Type:" }, function(task_type)
      if not task_type then
        return
      end

      vim.ui.select({ "1 (high)", "2 (medium)", "3 (low)" }, { prompt = "Priority:" }, function(pri_str)
        if not pri_str then
          return
        end
        local priority = tonumber(pri_str:sub(1, 1))

        local id
        if parent_id then
          local child_num = fs.next_child_number(root, parent_id)
          id = parent_id .. "." .. child_num
        else
          local config = fs.read_config(root)
          id = fs.generate_id(root, config.prefix or "task")
        end
        local now = fs.now_iso()

        local task = task_mod.new({
          title = title,
          type = task_type,
          priority = priority,
        }, id, now)

        -- Open a scratch buffer for description
        M._description_buffer(task, root, id)
      end)
    end)
  end)
end

--- Reparent a task under a new parent via interactive selection.
---@param id string task ID
---@param opts? {on_complete?: fun(new_id: string)}
function M.reparent(id, opts)
  opts = opts or {}
  local fs = require("yaks.fs")
  local task_mod = require("yaks.task")

  local root = fs.find_root()
  if not root then
    vim.notify("yaks: no .yaks/ directory found", vim.log.levels.WARN)
    return
  end

  -- Collect subtree IDs for cycle prevention
  local all_entries = fs.list_all_tasks(root)
  local subtree_ids = { [id] = true }
  local queue = { id }
  while #queue > 0 do
    local qid = table.remove(queue, 1)
    local children = fs.find_children(root, qid)
    for _, child in ipairs(children) do
      subtree_ids[child.task.id] = true
      queue[#queue + 1] = child.task.id
    end
  end

  -- Build candidate list: all tasks except self and descendants
  local candidates = {}
  for _, entry in ipairs(all_entries) do
    if not subtree_ids[entry.task.id] then
      candidates[#candidates + 1] = string.format("%s: %s", entry.task.id, entry.task.title or "(untitled)")
    end
  end

  if #candidates == 0 then
    vim.notify("yaks: no valid parent candidates", vim.log.levels.WARN)
    return
  end

  vim.ui.select(candidates, { prompt = "Select new parent:" }, function(choice)
    if not choice then
      return
    end
    local new_parent_id = choice:match("^([^:]+)")
    local new_id, err = fs.reparent_task(root, id, new_parent_id)
    if not new_id then
      vim.notify("yaks: " .. (err or "reparent failed"), vim.log.levels.ERROR)
      return
    end
    vim.notify("yaks: reparented " .. id .. " → " .. new_id, vim.log.levels.INFO)
    M._post_write()
    if opts.on_complete then
      opts.on_complete(new_id)
    end
  end)
end

--- Unparent a task (make it a root task) with confirmation.
---@param id string task ID
---@param opts? {on_complete?: fun(new_id: string)}
function M.unparent(id, opts)
  opts = opts or {}
  local fs = require("yaks.fs")
  local task_mod = require("yaks.task")

  local root = fs.find_root()
  if not root then
    vim.notify("yaks: no .yaks/ directory found", vim.log.levels.WARN)
    return
  end

  if not task_mod.parent_id(id) then
    vim.notify("yaks: " .. id .. " is already a root task", vim.log.levels.INFO)
    return
  end

  vim.ui.select({ "Yes", "No" }, { prompt = "Unparent " .. id .. "?" }, function(choice)
    if choice ~= "Yes" then
      return
    end
    local new_id, err = fs.reparent_task(root, id, nil)
    if not new_id then
      vim.notify("yaks: " .. (err or "unparent failed"), vim.log.levels.ERROR)
      return
    end
    vim.notify("yaks: unparented " .. id .. " → " .. new_id, vim.log.levels.INFO)
    M._post_write()
    if opts.on_complete then
      opts.on_complete(new_id)
    end
  end)
end

--- Open a scratch buffer for entering a task description.
---@param task table
---@param root string
---@param id string
function M._description_buffer(task, root, id)
  vim.cmd(M.cross_split_cmd())
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)

  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(buf, "yaks://create/" .. id)

  local instructions = {
    "# Enter task description below (lines starting with # are stripped)",
    "# Task: " .. id .. " — " .. (task.title or ""),
    "# Type: " .. (task.type or "task") .. "  Priority: " .. (task.priority or 2),
    "# Save (:w) to create the task. Close without saving to cancel.",
    "",
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, instructions)

  -- Place cursor after the instructions
  vim.api.nvim_win_set_cursor(0, { #instructions, 0 })

  -- Resize the split
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(win, 15)

  -- Handle save
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    once = true,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      -- Strip comment lines
      local desc_lines = {}
      for _, line in ipairs(lines) do
        if not line:match("^#") then
          desc_lines[#desc_lines + 1] = line
        end
      end
      -- Trim leading and trailing blank lines
      while #desc_lines > 0 and desc_lines[1] == "" do
        table.remove(desc_lines, 1)
      end
      while #desc_lines > 0 and desc_lines[#desc_lines] == "" do
        table.remove(desc_lines)
      end

      if #desc_lines > 0 then
        task.description = table.concat(desc_lines, "\n") .. "\n"
        -- Add description to _keys if not already there
        local has_desc = false
        for _, k in ipairs(task._keys) do
          if k == "description" then
            has_desc = true
            break
          end
        end
        if not has_desc then
          task._keys[#task._keys + 1] = "description"
        end
      end

      local fs = require("yaks.fs")
      local path = root .. "/hairy/" .. id .. ".md"
      fs.write_task(path, task)
      vim.notify("yaks: created " .. id, vim.log.levels.INFO)
      vim.bo[buf].modified = false

      -- Defer close + refresh so :wq's :q doesn't cascade to the list window
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win) == buf and #vim.api.nvim_list_wins() > 1 then
              vim.api.nvim_win_close(win, false)
              break
            end
          end
        end
        M._post_write()
      end)
    end,
  })
end

--- Edit a task's raw YAML file.
---@param id string task ID
function M.edit(id)
  local fs = require("yaks.fs")
  local root = fs.find_root()
  if not root then
    vim.notify("yaks: no .yaks/ directory found", vim.log.levels.WARN)
    return
  end

  local entry = fs.find_task(root, id)
  if not entry then
    vim.notify("yaks: task not found: " .. id, vim.log.levels.ERROR)
    return
  end

  -- Open the task file in a split
  vim.cmd(M.cross_split_cmd() .. " " .. vim.fn.fnameescape(entry.path))
  vim.bo.filetype = entry.path:sub(-3) == ".md" and "markdown" or "yaml"
  vim.wo.wrap = true
  vim.wo.linebreak = true

  -- Refresh list buffer on save (deferred so :wq completes window
  -- management before we touch the list buffer / cursor).
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = vim.api.nvim_get_current_buf(),
    callback = function()
      vim.schedule(function()
        M._post_write()
      end)
    end,
  })
end

--- Update a task field programmatically.
---@param id string task ID
---@param field string field name
---@param value string|number value
function M.update(id, field, value)
  local fs = require("yaks.fs")
  local root = fs.find_root()
  if not root then
    vim.notify("yaks: no .yaks/ directory found", vim.log.levels.WARN)
    return
  end

  local entry = fs.find_task(root, id)
  if not entry then
    vim.notify("yaks: task not found: " .. id, vim.log.levels.ERROR)
    return
  end

  local task = entry.task

  -- Type conversion
  if field == "priority" then
    value = tonumber(value)
    if not value or value < 1 or value > 3 then
      vim.notify("yaks: priority must be 1-3", vim.log.levels.ERROR)
      return
    end
  elseif field == "labels" then
    -- Parse comma-separated labels
    local labels = {}
    for label in value:gmatch("[^,]+") do
      labels[#labels + 1] = vim.trim(label)
    end
    value = labels
  end

  task[field] = value
  task.updated = fs.now_iso()

  -- Ensure the field is in _keys
  local found = false
  for _, k in ipairs(task._keys) do
    if k == field then
      found = true
      break
    end
  end
  if not found then
    task._keys[#task._keys + 1] = field
  end

  fs.write_task(entry.path, task)
  vim.notify("yaks: updated " .. id .. "." .. field, vim.log.levels.INFO)
  M._post_write()
end

--- Add a dependency to a task.
---@param id string task ID
---@param dep_id string dependency task ID
function M.dep_add(id, dep_id)
  local fs = require("yaks.fs")
  local root = fs.find_root()
  if not root then
    vim.notify("yaks: no .yaks/ directory found", vim.log.levels.WARN)
    return
  end

  local entry = fs.find_task(root, id)
  if not entry then
    vim.notify("yaks: task not found: " .. id, vim.log.levels.ERROR)
    return
  end

  -- Verify dep exists
  if not fs.find_task(root, dep_id) then
    vim.notify("yaks: dependency not found: " .. dep_id, vim.log.levels.ERROR)
    return
  end

  local task = entry.task
  local deps = task.depends_on or {}

  -- Check for duplicate
  for _, d in ipairs(deps) do
    if d == dep_id then
      vim.notify("yaks: dependency already exists", vim.log.levels.WARN)
      return
    end
  end

  deps[#deps + 1] = dep_id
  task.depends_on = deps
  task.updated = fs.now_iso()

  -- Add depends_on to _keys if not present
  local found = false
  for _, k in ipairs(task._keys) do
    if k == "depends_on" then
      found = true
      break
    end
  end
  if not found then
    -- Insert after updated, before labels/description
    local insert_pos = #task._keys + 1
    for i, k in ipairs(task._keys) do
      if k == "labels" or k == "description" then
        insert_pos = i
        break
      end
    end
    table.insert(task._keys, insert_pos, "depends_on")
  end

  fs.write_task(entry.path, task)
  vim.notify("yaks: added dependency " .. dep_id .. " to " .. id, vim.log.levels.INFO)
  M._post_write()
end

--- Remove a dependency from a task.
---@param id string task ID
---@param dep_id string dependency task ID
function M.dep_remove(id, dep_id)
  local fs = require("yaks.fs")
  local root = fs.find_root()
  if not root then
    vim.notify("yaks: no .yaks/ directory found", vim.log.levels.WARN)
    return
  end

  local entry = fs.find_task(root, id)
  if not entry then
    vim.notify("yaks: task not found: " .. id, vim.log.levels.ERROR)
    return
  end

  local task = entry.task
  local deps = task.depends_on or {}

  local new_deps = {}
  local removed = false
  for _, d in ipairs(deps) do
    if d == dep_id then
      removed = true
    else
      new_deps[#new_deps + 1] = d
    end
  end

  if not removed then
    vim.notify("yaks: dependency not found: " .. dep_id, vim.log.levels.WARN)
    return
  end

  if #new_deps == 0 then
    -- Remove depends_on entirely (match yak.py behavior)
    task.depends_on = nil
    local new_keys = {}
    for _, k in ipairs(task._keys) do
      if k ~= "depends_on" then
        new_keys[#new_keys + 1] = k
      end
    end
    task._keys = new_keys
  else
    task.depends_on = new_deps
  end

  task.updated = fs.now_iso()
  fs.write_task(entry.path, task)
  vim.notify("yaks: removed dependency " .. dep_id .. " from " .. id, vim.log.levels.INFO)
  M._post_write()
end

--- Print task statistics.
function M.stats()
  local fs = require("yaks.fs")
  local task_mod = require("yaks.task")
  local root = fs.find_root()
  if not root then
    vim.notify("yaks: no .yaks/ directory found", vim.log.levels.WARN)
    return
  end

  local all = fs.list_all_tasks(root)
  local st = task_mod.stats(all)

  local lines = { "Yaks Stats:" }
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  By status:"
  for _, status in ipairs(fs.STATUSES) do
    lines[#lines + 1] = string.format("    %-10s %d", fs.STATUS_LABELS[status], st.by_status[status] or 0)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  By type:"
  for t, count in pairs(st.by_type) do
    lines[#lines + 1] = string.format("    %-10s %d", t, count)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  By priority:"
  for p = 1, 3 do
    if st.by_priority[p] then
      lines[#lines + 1] = string.format("    p%d         %d", p, st.by_priority[p])
    end
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Post-write hook: refresh list buffer and invalidate statusline cache.
function M._post_write()
  require("yaks.statusline").invalidate()
  local list_buf = require("yaks.ui.list").get_buf()
  if list_buf then
    require("yaks.ui.list").refresh()
  end
end

return M
