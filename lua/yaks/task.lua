--- Task model: filtering, sorting, dependency logic, and task construction.
local M = {}

--- Canonical key ordering for new tasks.
local KEY_ORDER = { "id", "title", "type", "priority", "created", "updated" }
local OPTIONAL_KEYS = { "depends_on", "labels", "description" }

--- Filter a list of task entries by criteria.
-- All specified criteria are combined with AND logic.
---@param entries table[] list of {status, task, path}
---@param opts table {status?, type?, priority?, label?}
---@return table[] filtered entries
function M.filter(entries, opts)
  opts = opts or {}
  local result = {}
  for _, entry in ipairs(entries) do
    local ok = true
    if opts.status and entry.status ~= opts.status then
      ok = false
    end
    if opts.type and entry.task.type ~= opts.type then
      ok = false
    end
    if opts.priority and entry.task.priority ~= opts.priority then
      ok = false
    end
    if opts.label then
      local labels = entry.task.labels or {}
      local found = false
      for _, l in ipairs(labels) do
        if l == opts.label then
          found = true
          break
        end
      end
      if not found then
        ok = false
      end
    end
    if ok then
      result[#result + 1] = entry
    end
  end
  return result
end

--- Sort task entries by priority (ascending), then by ID.
---@param entries table[] list of {status, task, path}
function M.sort_by_priority(entries)
  table.sort(entries, function(a, b)
    local pa = a.task.priority or 99
    local pb = b.task.priority or 99
    if pa ~= pb then
      return pa < pb
    end
    return (a.task.id or "") < (b.task.id or "")
  end)
end

--- Build a set of shorn task IDs from all entries.
---@param all_entries table[]
---@return table<string, boolean>
local function shorn_set(all_entries)
  local set = {}
  for _, entry in ipairs(all_entries) do
    if entry.status == "shorn" then
      set[entry.task.id] = true
    end
  end
  return set
end

--- Get "next" tasks: hairy tasks whose dependencies are all shorn.
---@param all_entries table[] all task entries
---@return table[] filtered entries
function M.next_tasks(all_entries)
  local shorn = shorn_set(all_entries)
  local result = {}
  for _, entry in ipairs(all_entries) do
    if entry.status == "hairy" then
      local deps = entry.task.depends_on or {}
      local ready = true
      for _, dep_id in ipairs(deps) do
        if not shorn[dep_id] then
          ready = false
          break
        end
      end
      if ready then
        result[#result + 1] = entry
      end
    end
  end
  return result
end

--- Get "tangled" tasks: hairy tasks with at least one unshorn dependency.
---@param all_entries table[] all task entries
---@return table[] filtered entries
function M.tangled_tasks(all_entries)
  local shorn = shorn_set(all_entries)
  local result = {}
  for _, entry in ipairs(all_entries) do
    if entry.status == "hairy" then
      local deps = entry.task.depends_on or {}
      if #deps > 0 then
        for _, dep_id in ipairs(deps) do
          if not shorn[dep_id] then
            result[#result + 1] = entry
            break
          end
        end
      end
    end
  end
  return result
end

--- Check if a specific task is tangled.
---@param entry table {status, task, path}
---@param all_entries table[] all task entries
---@return boolean
function M.is_tangled(entry, all_entries)
  if entry.status ~= "hairy" then
    return false
  end
  local deps = entry.task.depends_on or {}
  if #deps == 0 then
    return false
  end
  local shorn = shorn_set(all_entries)
  for _, dep_id in ipairs(deps) do
    if not shorn[dep_id] then
      return true
    end
  end
  return false
end

--- Compute task statistics.
---@param all_entries table[]
---@return table {by_status, by_type, by_priority}
function M.stats(all_entries)
  local by_status = { hairy = 0, shaving = 0, shorn = 0 }
  local by_type = {}
  local by_priority = {}

  for _, entry in ipairs(all_entries) do
    by_status[entry.status] = (by_status[entry.status] or 0) + 1

    local t = entry.task.type or "unknown"
    by_type[t] = (by_type[t] or 0) + 1

    local p = entry.task.priority or 0
    by_priority[p] = (by_priority[p] or 0) + 1
  end

  return {
    by_status = by_status,
    by_type = by_type,
    by_priority = by_priority,
  }
end

--- Construct a new task table with proper _keys ordering.
---@param fields table {title, type?, priority?, description?, depends_on?, labels?}
---@param id string generated task ID
---@param now string ISO 8601 timestamp
---@return table task
function M.new(fields, id, now)
  local task = {
    id = id,
    title = fields.title,
    type = fields.type or "task",
    priority = fields.priority or 2,
    created = now,
    updated = now,
  }

  -- Build _keys in canonical order
  local keys = {}
  for _, k in ipairs(KEY_ORDER) do
    keys[#keys + 1] = k
  end
  for _, k in ipairs(OPTIONAL_KEYS) do
    if fields[k] then
      task[k] = fields[k]
      keys[#keys + 1] = k
    end
  end

  task._keys = keys
  return task
end

--- Extract the parent task ID from a child task ID.
-- Child IDs have the form "parent.N" where N is a purely numeric suffix.
-- Handles prefixes containing dots (e.g. "yaks.nvim-a103.1" → "yaks.nvim-a103").
---@param task_id string
---@return string|nil parent ID, or nil if not a child task
function M.parent_id(task_id)
  local dot = task_id:match(".*()%.")  -- position of rightmost dot
  if not dot then return nil end
  local suffix = task_id:sub(dot + 1)
  if suffix:match("^%d+$") then
    return task_id:sub(1, dot - 1)
  end
  return nil
end

--- Validate a task table has required fields with correct types.
---@param task table
---@return boolean ok
---@return string|nil error message
function M.validate(task)
  if not task.id or type(task.id) ~= "string" then
    return false, "missing or invalid id"
  end
  if not task.title or type(task.title) ~= "string" then
    return false, "missing or invalid title"
  end
  local valid_types = { bug = true, feature = true, task = true }
  if task.type and not valid_types[task.type] then
    return false, "invalid type: " .. tostring(task.type)
  end
  if task.priority and type(task.priority) ~= "number" then
    return false, "priority must be a number"
  end
  if task.priority and (task.priority < 1 or task.priority > 3) then
    return false, "priority must be 1-3"
  end
  return true
end

return M
