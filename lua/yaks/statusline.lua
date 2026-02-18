--- Statusline component for yaks.nvim.
-- Returns a short summary like "Yaks: 3H 1S 2N" for use in lualine/heirline.
local M = {}

---@type {text: string, expires_at: number}
local cache = { text = "", expires_at = 0 }

--- Invalidate the statusline cache (called after write operations).
function M.invalidate()
  cache.expires_at = 0
end

--- Get the statusline text.
-- Returns empty string if no .yaks/ root is found.
---@return string
function M.get()
  local now = vim.loop.now() / 1000
  local config = require("yaks").config

  if now < cache.expires_at then
    return cache.text
  end

  local fs = require("yaks.fs")
  local root = fs.find_root()
  if not root then
    cache.text = ""
    cache.expires_at = now + (config.statusline_ttl or 5)
    return cache.text
  end

  local task_mod = require("yaks.task")
  local all = fs.list_all_tasks(root)
  local st = task_mod.stats(all)

  local parts = {}
  if st.by_status.hairy > 0 then
    parts[#parts + 1] = st.by_status.hairy .. "H"
  end
  if st.by_status.shaving > 0 then
    parts[#parts + 1] = st.by_status.shaving .. "S"
  end
  if st.by_status.shorn > 0 then
    parts[#parts + 1] = st.by_status.shorn .. "N"
  end

  if #parts > 0 then
    cache.text = "Yaks: " .. table.concat(parts, " ")
  else
    cache.text = ""
  end

  cache.expires_at = now + (config.statusline_ttl or 5)
  return cache.text
end

return M
