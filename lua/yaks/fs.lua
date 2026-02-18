--- Filesystem operations for yaks.nvim.
-- Reads and writes .yaks/ task files directly.
local parser = require("yaks.parser")

local M = {}

M.STATUSES = { "hairy", "shaving", "shorn" }

--- Map from status directory to display label.
M.STATUS_LABELS = {
  hairy = "Hairy",
  shaving = "Shaving",
  shorn = "Shorn",
}

--- Find the .yaks/ root directory, searching upward from start_dir.
---@param start_dir? string defaults to cwd
---@return string|nil root path to the .yaks/ directory
function M.find_root(start_dir)
  start_dir = start_dir or vim.fn.getcwd()
  local found = vim.fs.find(".yaks", {
    upward = true,
    type = "directory",
    path = start_dir,
  })
  if found and found[1] then
    return found[1]
  end
  return nil
end

--- Read and parse the project config (.yaks/config.yaml).
---@param root string path to .yaks/
---@return table config
function M.read_config(root)
  local path = root .. "/config.yaml"
  local content = M._read_file(path)
  if content then
    local config = parser.parse(content)
    if config then
      return config
    end
  end
  -- Fallback: derive prefix from the parent directory name
  local parent = vim.fn.fnamemodify(root, ":h:t")
  return { prefix = parent }
end

--- Read a file's contents.
---@param path string
---@return string|nil
function M._read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

--- Write content to a file.
---@param path string
---@param content string
---@return boolean ok
function M._write_file(path, content)
  local f = io.open(path, "w")
  if not f then
    return false
  end
  f:write(content)
  f:close()
  return true
end

--- Read and parse a task YAML file.
---@param path string
---@return table|nil task
function M.read_task(path)
  local content = M._read_file(path)
  if not content then
    return nil
  end
  return parser.parse(content)
end

--- Serialize and write a task to a file.
---@param path string
---@param task table
---@return boolean ok
function M.write_task(path, task)
  local yaml = parser.serialize(task)
  return M._write_file(path, yaml)
end

--- List tasks in a specific status directory.
---@param root string path to .yaks/
---@param status string "hairy", "shaving", or "shorn"
---@return table[] list of {status, task, path} entries
function M.list_tasks(root, status)
  local dir = root .. "/" .. status
  local files = vim.fn.glob(dir .. "/*.yaml", false, true)
  table.sort(files)
  local results = {}
  for _, path in ipairs(files) do
    local task = M.read_task(path)
    if task then
      results[#results + 1] = {
        status = status,
        task = task,
        path = path,
      }
    end
  end
  return results
end

--- List all tasks across all status directories.
---@param root string path to .yaks/
---@return table[] list of {status, task, path} entries
function M.list_all_tasks(root)
  local all = {}
  for _, status in ipairs(M.STATUSES) do
    local tasks = M.list_tasks(root, status)
    for _, entry in ipairs(tasks) do
      all[#all + 1] = entry
    end
  end
  return all
end

--- Find a task by ID across all status directories.
---@param root string path to .yaks/
---@param id string task ID
---@return table|nil entry {status, task, path} or nil
function M.find_task(root, id)
  for _, status in ipairs(M.STATUSES) do
    local path = root .. "/" .. status .. "/" .. id .. ".yaml"
    local task = M.read_task(path)
    if task then
      return {
        status = status,
        task = task,
        path = path,
      }
    end
  end
  return nil
end

--- Move a task to a different status directory.
-- Renames the file first, then updates the `updated` timestamp (matches yak.py behavior).
---@param root string path to .yaks/
---@param id string task ID
---@param dest_status string target status directory
---@return boolean ok
---@return string|nil error message
function M.move_task(root, id, dest_status)
  local entry = M.find_task(root, id)
  if not entry then
    return false, "task not found: " .. id
  end
  if entry.status == dest_status then
    return false, "task already in " .. dest_status
  end

  local new_path = root .. "/" .. dest_status .. "/" .. id .. ".yaml"
  local ok = vim.fn.rename(entry.path, new_path)
  if ok ~= 0 then
    return false, "failed to rename file"
  end

  -- Update the timestamp
  local task = M.read_task(new_path)
  if task then
    task.updated = M.now_iso()
    M.write_task(new_path, task)
  end

  return true
end

--- Generate a unique task ID.
---@param root string path to .yaks/
---@param prefix string ID prefix from config
---@return string id
function M.generate_id(root, prefix)
  -- Collect all existing IDs
  local existing = {}
  for _, status in ipairs(M.STATUSES) do
    local files = vim.fn.glob(root .. "/" .. status .. "/*.yaml", false, true)
    for _, path in ipairs(files) do
      local stem = vim.fn.fnamemodify(path, ":t:r")
      existing[stem] = true
    end
  end

  -- Generate random hex IDs until we find one that doesn't collide
  for _ = 1, 100 do
    local hex = string.format("%04x", math.random(0, 0xFFFF))
    local id = prefix .. "-" .. hex
    if not existing[id] then
      return id
    end
  end

  error("failed to generate unique ID after 100 attempts")
end

--- Get current time as ISO 8601 string.
---@return string
function M.now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

return M
