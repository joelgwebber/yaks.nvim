--- Minimal YAML parser and serializer for yaks task files.
-- Handles the subset of YAML produced by yak.py's SafeDumper:
-- flat key-value pairs, block lists, block scalars, single-quoted strings.
local M = {}

--- Check if a string value needs single-quoting (matching PyYAML SafeDumper rules).
---@param s string
---@return boolean
local function needs_quoting(s)
  if s == "" then
    return true
  end
  -- Numeric values
  if s:match("^[+-]?%d+$") or s:match("^[+-]?%d*%.%d+$") then
    return true
  end
  -- YAML booleans and null
  local lower = s:lower()
  local reserved = {
    ["true"] = true, ["false"] = true,
    ["yes"] = true, ["no"] = true,
    ["on"] = true, ["off"] = true,
    ["null"] = true, ["~"] = true,
  }
  if reserved[lower] then
    return true
  end
  -- Contains colon-space or space-hash
  if s:find(": ") or s:find(" #") then
    return true
  end
  -- Starts with special characters
  if s:match("^[#%-%[%]{}&*!|>'\"%@`,?]") then
    return true
  end
  -- ISO 8601 timestamp pattern
  if s:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d") then
    return true
  end
  return false
end

--- Single-quote a string, escaping embedded single quotes by doubling them.
---@param s string
---@return string
local function single_quote(s)
  return "'" .. s:gsub("'", "''") .. "'"
end

--- Unquote a single-quoted string.
---@param s string
---@return string
local function unquote_single(s)
  return s:gsub("''", "'")
end

--- Parse a YAML text string into a table.
-- Returns the parsed table with a `_keys` array preserving key order,
-- or nil and an error message on failure.
---@param text string
---@return table|nil, string|nil
function M.parse(text)
  local result = {}
  local keys = {}
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local i = 1
  while i <= #lines do
    local line = lines[i]

    -- Skip blank lines and comments
    if line:match("^%s*$") or line:match("^%s*#") then
      i = i + 1
    -- Key-value line
    elseif line:match("^([%w_][%w_%-%.]*):") then
      local key, rest = line:match("^([%w_][%w_%-%.]*):(.*)$")
      if not key then
        return nil, "parse error at line " .. i .. ": " .. line
      end
      rest = rest or ""

      -- Strip leading space from value portion
      local value_str = rest:match("^%s(.*)$") or ""

      if value_str == "" and i < #lines and lines[i + 1]:match("^%- ") then
        -- Block list: next lines are `- item`
        local items = {}
        i = i + 1
        while i <= #lines and lines[i]:match("^%- ") do
          local item = lines[i]:match("^%- (.*)$")
          if item then
            -- Unquote single-quoted list items
            local sq = item:match("^'(.*)'$")
            if sq then
              item = unquote_single(sq)
            end
          end
          items[#items + 1] = item or ""
          i = i + 1
        end
        result[key] = items
        keys[#keys + 1] = key
      elseif value_str == "|" or value_str == "|-" or value_str == "|+" then
        -- Block scalar
        local chomp = value_str
        local block_lines = {}
        i = i + 1
        while i <= #lines do
          local bline = lines[i]
          if bline:match("^  ") then
            block_lines[#block_lines + 1] = bline:sub(3)
            i = i + 1
          elseif bline == "" then
            -- Empty line within block scalar
            block_lines[#block_lines + 1] = ""
            i = i + 1
          else
            break
          end
        end
        local text_val = table.concat(block_lines, "\n")
        if chomp == "|" then
          -- Clip: single trailing newline
          text_val = text_val:gsub("\n*$", "") .. "\n"
        elseif chomp == "|-" then
          -- Strip: no trailing newline
          text_val = text_val:gsub("\n*$", "")
        elseif chomp == "|+" then
          -- Keep: preserve all trailing newlines, plus one
          text_val = text_val .. "\n"
        end
        result[key] = text_val
        keys[#keys + 1] = key
      elseif value_str == "[]" then
        -- Empty list
        result[key] = {}
        keys[#keys + 1] = key
        i = i + 1
      else
        -- Scalar value
        local val = value_str
        -- Single-quoted string
        local sq = val:match("^'(.*)'$")
        if sq then
          val = unquote_single(sq)
        -- Double-quoted string
        elseif val:match('^"(.*)"$') then
          val = val:match('^"(.*)"$')
        else
          -- Try integer
          local num = tonumber(val)
          if num and val:match("^%-?%d+$") then
            val = num
          end
          -- Otherwise leave as string
        end
        result[key] = val
        keys[#keys + 1] = key
        i = i + 1
      end
    else
      -- Unknown line, skip
      i = i + 1
    end
  end

  result._keys = keys
  return result
end

--- Serialize a task table to YAML string.
-- Uses `_keys` to preserve key ordering.
---@param task table
---@return string
function M.serialize(task)
  local parts = {}
  local keys = task._keys or {}

  for _, key in ipairs(keys) do
    local val = task[key]
    if val == nil then
      -- Skip nil values (deleted keys)
    elseif type(val) == "number" then
      parts[#parts + 1] = key .. ": " .. tostring(val)
    elseif type(val) == "table" then
      if #val == 0 then
        parts[#parts + 1] = key .. ": []"
      else
        parts[#parts + 1] = key .. ":"
        for _, item in ipairs(val) do
          if needs_quoting(tostring(item)) then
            parts[#parts + 1] = "- " .. single_quote(tostring(item))
          else
            parts[#parts + 1] = "- " .. tostring(item)
          end
        end
      end
    elseif type(val) == "string" then
      if val:find("\n") then
        -- Block scalar — strip the trailing newline before splitting lines,
        -- then emit each line indented by 2 spaces
        parts[#parts + 1] = key .. ": |"
        local body = val:gsub("\n$", "")
        for bline in (body .. "\n"):gmatch("([^\n]*)\n") do
          parts[#parts + 1] = "  " .. bline
        end
      elseif needs_quoting(val) then
        parts[#parts + 1] = key .. ": " .. single_quote(val)
      else
        parts[#parts + 1] = key .. ": " .. val
      end
    end
  end

  return table.concat(parts, "\n") .. "\n"
end

--- Parse a markdown file with YAML frontmatter into a task table.
-- Splits on `---` delimiters, parses YAML via M.parse(), and extracts the
-- markdown body as task.description.
---@param text string
---@return table|nil, string|nil
function M.parse_frontmatter(text)
  -- Match opening and closing --- delimiters
  local yaml_block, body = text:match("^%-%-%-\n(.-)\n%-%-%-\n(.*)$")
  if not yaml_block then
    -- Try without body (frontmatter only, no trailing content)
    yaml_block = text:match("^%-%-%-\n(.-)\n%-%-%-$")
    body = nil
  end
  if not yaml_block then
    return nil, "no frontmatter delimiters found"
  end

  local task, err = M.parse(yaml_block)
  if not task then
    return nil, err
  end

  -- Extract markdown body as description
  if body then
    -- Strip single leading blank line (conventional separator)
    body = body:gsub("^\n", "")
    if body ~= "" then
      -- Ensure trailing newline
      if not body:match("\n$") then
        body = body .. "\n"
      end
      task.description = body
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
  end

  return task
end

--- Serialize a task table to markdown with YAML frontmatter.
-- Description is written as the markdown body, not in the YAML block.
---@param task table
---@return string
function M.serialize_frontmatter(task)
  -- Build a copy of _keys without "description" for the YAML block
  local yaml_keys = {}
  for _, k in ipairs(task._keys or {}) do
    if k ~= "description" then
      yaml_keys[#yaml_keys + 1] = k
    end
  end

  -- Build a shallow copy with the filtered keys for serialization
  local yaml_task = {}
  for k, v in pairs(task) do
    if k ~= "description" and k ~= "_keys" then
      yaml_task[k] = v
    end
  end
  yaml_task._keys = yaml_keys

  local yaml = M.serialize(yaml_task)
  local parts = { "---\n", yaml, "---\n" }

  if task.description and task.description ~= "" then
    parts[#parts + 1] = "\n"
    parts[#parts + 1] = task.description
    -- Ensure trailing newline
    if not task.description:match("\n$") then
      parts[#parts + 1] = "\n"
    end
  end

  return table.concat(parts)
end

return M
