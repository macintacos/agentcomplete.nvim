---Backend-agnostic completion core: parse the trigger context at the cursor and
---assemble normalized completion items. Both the blink.cmp and native adapters
---consume this same module, which is what keeps their behavior identical.
---@class AgentComplete.Sources
local M = {}

local scan = require "agentcomplete.scan"

---@class AgentComplete.Context
---@field trigger '"/"'|'"@"' The trigger character that opened completion.
---@field query string Text typed after the trigger, up to the cursor.
---@field start_col integer 0-based byte column where the query begins (after the trigger).

---@class AgentComplete.Item
---@field label string Display text, including the trigger (e.g. `/deploy`, `@src/init.lua`).
---@field insert_text string Text that replaces the query (the bare name/path).
---@field kind '"skill"'|'"command"'|'"file"'
---@field detail string|nil Short description shown alongside the item.

---Parse the completion context from a line and a 0-based byte cursor column.
---A trigger fires only at the start of a non-whitespace run, so `/` and `@`
---mid-word (e.g. `foo/bar`) do not trigger.
---@param line string Full line text.
---@param col integer 0-based byte column of the cursor (as from nvim_win_get_cursor).
---@return AgentComplete.Context|nil
function M.context(line, col)
  local before = line:sub(1, col)
  local i = #before
  while i > 0 and not before:sub(i, i):match "%s" do
    i = i - 1
  end
  local run_start = i + 1 -- 1-based index of the run's first char == 0-based col of the query start
  local first = before:sub(run_start, run_start)
  if first == "/" or first == "@" then
    return { trigger = first, query = before:sub(run_start + 1), start_col = run_start }
  end
  return nil
end

---Case-insensitive prefix match (an empty query matches everything).
---@param name string
---@param query string
---@return boolean
local function matches(name, query)
  if query == "" then
    return true
  end
  return name:lower():sub(1, #query) == query:lower()
end

---Build the completion items for a session and context.
---@param session AgentComplete.Session
---@param ctx AgentComplete.Context|nil
---@return AgentComplete.Item[]
function M.items(session, ctx)
  if not ctx then
    return {}
  end
  local enabled = session.sources or {}
  local out = {}
  if ctx.trigger == "/" and enabled.slash ~= false then
    for _, s in ipairs(scan.skills(session.skill_dirs)) do
      if matches(s.name, ctx.query) then
        table.insert(out, { label = "/" .. s.name, insert_text = s.name, kind = "skill", detail = s.description })
      end
    end
    -- Markdown commands (from command_dirs) then any tool-specific extra_commands
    -- (e.g. OpenCode config-map commands), de-duplicated by name across both.
    local seen_cmd = {}
    local function add_command(c)
      if seen_cmd[c.name] then
        return
      end
      seen_cmd[c.name] = true
      if matches(c.name, ctx.query) then
        table.insert(out, { label = "/" .. c.name, insert_text = c.name, kind = "command", detail = c.description })
      end
    end
    for _, c in ipairs(scan.commands(session.command_dirs)) do
      add_command(c)
    end
    for _, c in ipairs(session.extra_commands or {}) do
      add_command(c)
    end
  elseif ctx.trigger == "@" and enabled.file ~= false then
    for _, f in ipairs(scan.files(session.cwd)) do
      if matches(f, ctx.query) then
        table.insert(out, { label = "@" .. f, insert_text = f, kind = "file" })
      end
    end
  end
  return out
end

return M
