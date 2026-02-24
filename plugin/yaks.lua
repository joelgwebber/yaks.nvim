-- yaks.nvim plugin entry point
-- Guard: require Neovim 0.10+
if vim.fn.has("nvim-0.10") ~= 1 then
  return
end

-- Guard: don't load twice
if vim.g.loaded_yaks then
  return
end
vim.g.loaded_yaks = true

--- Tab-complete task IDs.
---@return string[]
local function complete_task_id()
  local ok, fs = pcall(require, "yaks.fs")
  if not ok then
    return {}
  end
  local root = fs.find_root()
  if not root then
    return {}
  end
  local ids = {}
  for _, status in ipairs(fs.STATUSES) do
    local files = vim.fn.glob(root .. "/" .. status .. "/*.yaml", false, true)
    for _, path in ipairs(files) do
      ids[#ids + 1] = vim.fn.fnamemodify(path, ":t:r")
    end
  end
  table.sort(ids)
  return ids
end

-- ── User commands ─────────────────────────────────────────────────

vim.api.nvim_create_user_command("Yaks", function(opts)
  local split = opts.fargs[1]
  if split and split ~= "vertical" and split ~= "horizontal" then
    vim.notify("Yaks: direction must be 'vertical' or 'horizontal'", vim.log.levels.ERROR)
    return
  end
  require("yaks").list({ split = split })
end, {
  nargs = "?",
  complete = function()
    return { "vertical", "horizontal" }
  end,
  desc = "Open Yaks task list",
})

vim.api.nvim_create_user_command("YaksNext", function()
  require("yaks").next()
end, { desc = "Show tasks ready to shave" })

vim.api.nvim_create_user_command("YaksTangled", function()
  require("yaks").tangled()
end, { desc = "Show tangled tasks" })

vim.api.nvim_create_user_command("YaksShow", function(opts)
  require("yaks").show(opts.args)
end, {
  desc = "Show task details",
  nargs = 1,
  complete = function()
    return complete_task_id()
  end,
})

vim.api.nvim_create_user_command("YaksShave", function(opts)
  require("yaks").shave(opts.args)
end, {
  desc = "Move task to shaving",
  nargs = 1,
  complete = function()
    return complete_task_id()
  end,
})

vim.api.nvim_create_user_command("YaksShorn", function(opts)
  require("yaks").shorn(opts.args)
end, {
  desc = "Move task to shorn",
  nargs = 1,
  complete = function()
    return complete_task_id()
  end,
})

vim.api.nvim_create_user_command("YaksRegrow", function(opts)
  require("yaks").regrow(opts.args)
end, {
  desc = "Move task back to hairy",
  nargs = 1,
  complete = function()
    return complete_task_id()
  end,
})

vim.api.nvim_create_user_command("YaksCreate", function(opts)
  local parent_id = opts.args ~= "" and opts.args or nil
  require("yaks").create({ parent_id = parent_id })
end, {
  desc = "Create a new task (optional: parent task ID for child creation)",
  nargs = "?",
  complete = function()
    return complete_task_id()
  end,
})

vim.api.nvim_create_user_command("YaksEdit", function(opts)
  require("yaks").edit(opts.args)
end, {
  desc = "Edit task YAML",
  nargs = 1,
  complete = function()
    return complete_task_id()
  end,
})

vim.api.nvim_create_user_command("YaksUpdate", function(opts)
  local args = vim.split(opts.args, " ", { trimempty = true })
  if #args < 3 then
    vim.notify("Usage: YaksUpdate <id> <field> <value>", vim.log.levels.ERROR)
    return
  end
  local id = args[1]
  local field = args[2]
  local value = table.concat(vim.list_slice(args, 3), " ")
  require("yaks").update(id, field, value)
end, {
  desc = "Update a task field",
  nargs = "+",
  complete = function(_, cmdline)
    local parts = vim.split(cmdline, " ", { trimempty = true })
    if #parts <= 2 then
      return complete_task_id()
    elseif #parts == 3 then
      return { "title", "type", "priority", "labels", "description" }
    end
    return {}
  end,
})

vim.api.nvim_create_user_command("YaksDep", function(opts)
  local args = vim.split(opts.args, " ", { trimempty = true })
  if #args < 3 then
    vim.notify("Usage: YaksDep {add|remove} <id> <dep_id>", vim.log.levels.ERROR)
    return
  end
  local action = args[1]
  local id = args[2]
  local dep_id = args[3]
  if action == "add" then
    require("yaks").dep_add(id, dep_id)
  elseif action == "remove" then
    require("yaks").dep_remove(id, dep_id)
  else
    vim.notify("YaksDep: action must be 'add' or 'remove'", vim.log.levels.ERROR)
  end
end, {
  desc = "Manage task dependencies",
  nargs = "+",
  complete = function(_, cmdline)
    local parts = vim.split(cmdline, " ", { trimempty = true })
    if #parts <= 2 then
      return { "add", "remove" }
    else
      return complete_task_id()
    end
  end,
})

vim.api.nvim_create_user_command("YaksStats", function()
  require("yaks").stats()
end, { desc = "Show task statistics" })
