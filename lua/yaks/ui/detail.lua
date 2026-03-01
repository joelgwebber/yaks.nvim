--- Task detail view — opens in a split, reusing the same window.
local fs = require("yaks.fs")
local task_mod = require("yaks.task")

local M = {}

local ns = vim.api.nvim_create_namespace("yaks_detail")

--- Set up highlight groups for markdown rendering in descriptions.
local function setup_desc_highlights()
  local links = {
    YaksDescHeading = "Title",
    YaksDescCode = "Special",
    YaksDescLink = "Underlined",
    YaksDescListMarker = "Special",
  }
  for group, target in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
  vim.api.nvim_set_hl(0, "YaksDescBold", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "YaksDescItalic", { italic = true, default = true })
end

--- Persistent state for the detail window.
local state = { win = nil, buf = nil, task_id = nil, nav_lines = {}, history = {}, forward = {} }

--- Format a task for display in the detail buffer.
---@param entry table {status, task, path}
---@param all_entries table[] for dependency status lookup
---@param root string path to .yaks/
---@return string[] lines
---@return table<integer, string> nav_lines  line number → navigable task ID
local function format_detail(entry, all_entries, root)
  local t = entry.task
  local lines = {}
  local nav_lines = {}

  -- Build maps of task ID → status and task ID → title
  local id_status = {}
  local id_title = {}
  for _, e in ipairs(all_entries) do
    id_status[e.task.id] = e.status
    id_title[e.task.id] = e.task.title or "(untitled)"
  end

  lines[#lines + 1] = string.format("Task: %s", t.id or "???")
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("  Title:    %s", t.title or "(untitled)")
  lines[#lines + 1] = string.format("  Status:   %s", fs.STATUS_LABELS[entry.status] or entry.status)
  lines[#lines + 1] = string.format("  Type:     %s", t.type or "task")
  lines[#lines + 1] = string.format("  Priority: %d", t.priority or 0)
  lines[#lines + 1] = string.format("  Created:  %s", t.created or "")
  lines[#lines + 1] = string.format("  Updated:  %s", t.updated or "")

  -- Parent
  local pid = task_mod.parent_id(t.id)
  if pid and id_status[pid] then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Parent:"
    lines[#lines + 1] = string.format("    %s (%s) — %s", pid, id_status[pid], id_title[pid] or "(untitled)")
    nav_lines[#lines] = pid
  end

  -- Children
  local children = fs.find_children(root, t.id)
  if #children > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Children:"
    for _, child in ipairs(children) do
      local title = child.task.title or "(untitled)"
      lines[#lines + 1] = string.format("    %s (%s) — %s", child.task.id, child.status, title)
      nav_lines[#lines] = child.task.id
    end
  end

  -- Dependencies
  local deps = t.depends_on or {}
  if #deps > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Dependencies:"
    for _, dep_id in ipairs(deps) do
      local dep_status = id_status[dep_id] or "unknown"
      lines[#lines + 1] = string.format("    %s (%s)", dep_id, dep_status)
      nav_lines[#lines] = dep_id
    end
  end

  -- Labels
  local labels = t.labels or {}
  if #labels > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("  Labels:   %s", table.concat(labels, ", "))
  end

  -- Description
  local desc_start, desc_end
  if t.description and t.description ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Description:"
    desc_start = #lines + 1
    for dline in (t.description .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines + 1] = "    " .. dline
    end
    -- Remove trailing empty line from description
    if lines[#lines] == "    " then
      table.remove(lines)
    end
    desc_end = #lines
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("  File: %s", entry.path)

  return lines, nav_lines, desc_start, desc_end
end

--- Highlight markdown syntax in description lines using extmarks with concealment.
---@param buf integer
---@param lines string[]
---@param desc_start integer 1-indexed first description line
---@param desc_end integer 1-indexed last description line
local function highlight_description(buf, lines, desc_start, desc_end)
  if not desc_start or not desc_end then
    return
  end

  local set = vim.api.nvim_buf_set_extmark

  for i = desc_start, desc_end do
    local line = lines[i]
    if not line then
      goto continue
    end
    local row = i - 1 -- 0-indexed

    -- All description lines have 4-space indent; content starts at col 4
    local content = line:sub(5) -- strip "    " prefix
    if content == "" then
      goto continue
    end

    -- Headers: "# Heading" (after the 4-space indent)
    local hashes, htext = content:match("^(#+)%s+(.*)")
    if hashes then
      -- Conceal "# " prefix
      set(buf, ns, row, 4, { end_col = 4 + #hashes + 1, conceal = "" })
      -- Highlight heading text
      set(buf, ns, row, 4 + #hashes + 1, { end_col = #line, hl_group = "YaksDescHeading" })
      goto continue
    end

    -- Track ranges covered by code spans and links to avoid bold/italic inside them
    local covered = {}

    -- Code spans: `code`
    local pos = 1
    while true do
      local cs = content:find("`", pos, true)
      if not cs then break end
      local ce = content:find("`", cs + 1, true)
      if not ce then break end
      -- Conceal opening backtick
      set(buf, ns, row, 4 + cs - 1, { end_col = 4 + cs, conceal = "" })
      -- Highlight code content
      if ce > cs + 1 then
        set(buf, ns, row, 4 + cs, { end_col = 4 + ce - 1, hl_group = "YaksDescCode" })
      end
      -- Conceal closing backtick
      set(buf, ns, row, 4 + ce - 1, { end_col = 4 + ce, conceal = "" })
      covered[#covered + 1] = { cs, ce }
      pos = ce + 1
    end

    -- Links: [text](url)
    pos = 1
    while true do
      local ls = content:find("%[", pos)
      if not ls then break end
      local le = content:find("%]%(", ls + 1)
      if not le then break end
      local ue = content:find("%)", le + 2)
      if not ue then break end
      -- Conceal opening [
      set(buf, ns, row, 4 + ls - 1, { end_col = 4 + ls, conceal = "" })
      -- Highlight link text
      if le > ls + 1 then
        set(buf, ns, row, 4 + ls, { end_col = 4 + le - 1, hl_group = "YaksDescLink" })
      end
      -- Conceal ](url)
      set(buf, ns, row, 4 + le - 1, { end_col = 4 + ue, conceal = "" })
      covered[#covered + 1] = { ls, ue }
      pos = ue + 1
    end

    -- Helper: check if a position falls inside a covered range
    local function is_covered(p)
      for _, r in ipairs(covered) do
        if p >= r[1] and p <= r[2] then return true end
      end
      return false
    end

    -- Bold: **text**
    pos = 1
    while true do
      local bs = content:find("%*%*", pos)
      if not bs then break end
      if is_covered(bs) then pos = bs + 2; goto nextbold end
      local be = content:find("%*%*", bs + 2)
      if not be then break end
      if is_covered(be) then pos = be + 2; goto nextbold end
      -- Conceal opening **
      set(buf, ns, row, 4 + bs - 1, { end_col = 4 + bs + 1, conceal = "" })
      -- Highlight bold content
      if be > bs + 2 then
        set(buf, ns, row, 4 + bs + 1, { end_col = 4 + be - 1, hl_group = "YaksDescBold" })
      end
      -- Conceal closing **
      set(buf, ns, row, 4 + be - 1, { end_col = 4 + be + 1, conceal = "" })
      covered[#covered + 1] = { bs, be + 1 }
      pos = be + 2
      ::nextbold::
    end

    -- Italic: *text* (single *, not preceded/followed by *)
    pos = 1
    while true do
      local is_pos = content:find("%*", pos)
      if not is_pos then break end
      if is_covered(is_pos) then pos = is_pos + 1; goto nextitalic end
      -- Skip if part of ** (bold)
      if content:sub(is_pos + 1, is_pos + 1) == "*" then pos = is_pos + 2; goto nextitalic end
      if is_pos > 1 and content:sub(is_pos - 1, is_pos - 1) == "*" then pos = is_pos + 1; goto nextitalic end
      -- Find closing *
      local ie = is_pos + 1
      while ie <= #content do
        local found = content:find("%*", ie)
        if not found then ie = nil; break end
        -- Skip ** at close
        if content:sub(found + 1, found + 1) == "*" or (found > 1 and content:sub(found - 1, found - 1) == "*") then
          ie = found + 1
        else
          ie = found
          break
        end
      end
      if not ie or is_covered(ie) then pos = is_pos + 1; goto nextitalic end
      set(buf, ns, row, 4 + is_pos - 1, { end_col = 4 + is_pos, conceal = "" })
      if ie > is_pos + 1 then
        set(buf, ns, row, 4 + is_pos, { end_col = 4 + ie - 1, hl_group = "YaksDescItalic" })
      end
      set(buf, ns, row, 4 + ie - 1, { end_col = 4 + ie, conceal = "" })
      pos = ie + 1
      ::nextitalic::
    end

    -- Italic: _text_
    pos = 1
    while true do
      local us = content:find("_", pos, true)
      if not us then break end
      if is_covered(us) then pos = us + 1; goto nextunder end
      local ue_pos = content:find("_", us + 1, true)
      if not ue_pos then break end
      if is_covered(ue_pos) then pos = ue_pos + 1; goto nextunder end
      set(buf, ns, row, 4 + us - 1, { end_col = 4 + us, conceal = "" })
      if ue_pos > us + 1 then
        set(buf, ns, row, 4 + us, { end_col = 4 + ue_pos - 1, hl_group = "YaksDescItalic" })
      end
      set(buf, ns, row, 4 + ue_pos - 1, { end_col = 4 + ue_pos, conceal = "" })
      pos = ue_pos + 1
      ::nextunder::
    end

    -- List markers: "- " or "* " at start of content
    if content:match("^[%-%*]%s") then
      set(buf, ns, row, 4, { end_col = 5, hl_group = "YaksDescListMarker" })
    end

    ::continue::
  end
end

--- Apply highlights to the detail buffer.
---@param buf integer
---@param lines string[]
---@param desc_start integer|nil
---@param desc_end integer|nil
local function apply_highlights(buf, lines, desc_start, desc_end)
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

  -- Navigable lines (deps, parent, children) — highlight the task ID as a link
  for lnum, nav_id in pairs(state.nav_lines) do
    local line = lines[lnum]
    if line then
      local id_start = line:find(nav_id, 1, true)
      if id_start then
        vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, id_start - 1, {
          end_col = id_start - 1 + #nav_id,
          hl_group = "Underlined",
        })
      end
    end
  end

  highlight_description(buf, lines, desc_start, desc_end)
end

--- Set up buffer-local keymaps for the detail view.
---@param buf integer
---@param task_id string
local function setup_keymaps(buf, task_id)
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, desc = desc })
  end

  map("<CR>", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local nav_id = state.nav_lines[row]
    if nav_id then
      -- Push current task onto history stack, clear forward stack, then navigate
      state.history[#state.history + 1] = task_id
      state.forward = {}
      M.open(nav_id)
    end
  end, "Follow link")

  map("<C-o>", function()
    if #state.history > 0 then
      state.forward[#state.forward + 1] = task_id
      local prev_id = table.remove(state.history)
      M.open(prev_id)
    end
  end, "Go back")

  map("<C-i>", function()
    if #state.forward > 0 then
      state.history[#state.history + 1] = task_id
      local next_id = table.remove(state.forward)
      M.open(next_id)
    end
  end, "Go forward")

  map("q", function()
    state.history = {}
    state.forward = {}
    M.close()
  end, "Close detail")

  map("e", function()
    M.close()
    require("yaks").edit(task_id)
  end, "Edit raw YAML")

  map("s", function()
    require("yaks").shave(task_id)
    M.close()
  end, "Shave task")

  map("x", function()
    require("yaks").shorn(task_id)
    M.close()
  end, "Shorn task")

  map("r", function()
    require("yaks").regrow(task_id)
    M.close()
  end, "Regrow task")

  map("da", function()
    vim.ui.input({ prompt = "Add dependency (task ID): " }, function(dep_id)
      if dep_id and dep_id ~= "" then
        require("yaks").dep_add(task_id, dep_id)
        -- Reopen to reflect changes
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
        M.open(task_id)
      end
    end)
  end, "Remove dependency")

  map("C", function()
    require("yaks").create({ parent_id = task_id })
  end, "Create child task")

  map("P", function()
    require("yaks").reparent(task_id, {
      on_complete = function(new_id)
        M.open(new_id)
      end,
    })
  end, "Reparent task")

  map("U", function()
    require("yaks").unparent(task_id, {
      on_complete = function(new_id)
        M.open(new_id)
      end,
    })
  end, "Unparent task")
end

--- Open the detail view for a task, reusing an existing detail window.
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
  local lines, nav_lines, desc_start, desc_end = format_detail(entry, all_entries, root)
  state.nav_lines = nav_lines

  -- Create new buffer for this task
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "yaks-detail"
  -- Wipe any stale buffer with this name to avoid E95
  local buf_name = "yaks://detail/" .. task_id
  local existing = vim.fn.bufnr(buf_name)
  if existing ~= -1 and existing ~= buf then
    pcall(vim.api.nvim_buf_delete, existing, { force = true })
  end
  vim.api.nvim_buf_set_name(buf, buf_name)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Recover from module reload: find orphaned detail window
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local win_buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_is_valid(win_buf) and vim.bo[win_buf].filetype == "yaks-detail" then
        state.win = win
        break
      end
    end
  end

  -- Reuse existing detail window if valid and showing a yaks-detail buffer
  local reuse = state.win
    and vim.api.nvim_win_is_valid(state.win)
    and vim.bo[vim.api.nvim_win_get_buf(state.win)].filetype == "yaks-detail"

  if reuse then
    vim.api.nvim_win_set_buf(state.win, buf)
    vim.api.nvim_set_current_win(state.win)
  else
    vim.cmd(require("yaks").cross_split_cmd())
    vim.api.nvim_set_current_buf(buf)
    state.win = vim.api.nvim_get_current_win()
    -- Window options (set once on new split, not on reuse)
    vim.wo[state.win].wrap = true
    vim.wo[state.win].linebreak = true
  end

  state.buf = buf
  state.task_id = task_id

  -- Conceal settings for markdown rendering in descriptions
  vim.wo[state.win].conceallevel = 2
  vim.wo[state.win].concealcursor = "nc"

  setup_desc_highlights()
  apply_highlights(buf, lines, desc_start, desc_end)
  setup_keymaps(buf, task_id)

  -- Refresh on focus (re-read task data from disk)
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      if state.task_id then
        M.refresh()
      end
    end,
  })

  -- Clear state when window is closed manually
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.win),
    once = true,
    callback = function()
      state.win = nil
      state.buf = nil
      state.task_id = nil
    end,
  })
end

--- Refresh the detail buffer contents in-place.
function M.refresh()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) or not state.task_id then
    return
  end

  local root = fs.find_root()
  if not root then return end

  local entry = fs.find_task(root, state.task_id)
  if not entry then return end

  local all_entries = fs.list_all_tasks(root)
  local lines, nav_lines, desc_start, desc_end = format_detail(entry, all_entries, root)
  state.nav_lines = nav_lines

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  setup_desc_highlights()
  apply_highlights(state.buf, lines, desc_start, desc_end)
end

--- Close the detail window.
function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    if #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(state.win, false)
    end
  end
  state.win = nil
  state.buf = nil
  state.task_id = nil
end

return M
