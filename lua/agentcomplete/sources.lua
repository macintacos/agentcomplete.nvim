---Backend-agnostic completion core: parse the trigger context at the cursor and
---assemble normalized completion items. Both the blink.cmp and native adapters
---consume this same module, which is what keeps context parsing and item assembly
---identical between them. Filtering is not shared: the blink adapter narrows `@`
---items further, for the reason given in `backends/blink.lua`.
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
---@field kind '"skill"'|'"command"'|'"file"'|'"folder"'
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

---@class AgentComplete.Token
---@field trigger '"/"'|'"@"' The trigger character that opens the token.
---@field name string Text after the trigger (the skill/command name, or the path).
---@field col integer 0-based byte column of the trigger character — one before `Context.start_col`.
---@field end_col integer 0-based byte column just past the token's last character.

---Every trigger token on a line, left to right. A non-whitespace run is a token only
---when `M.context` accepts it, so mid-word `/` and `@` (`foo/bar`, `a@b.dev`) are
---excluded by the same rule that governs completion.
---
---Trailing punctuation is trimmed first, which is the one place this deliberately parts
---company with `M.context`: completion runs mid-word with the cursor at the token's end,
---so nothing has been typed after it yet, while this reads committed prose where
---`@src/init.lua, then` is ordinary. Leaving the comma in reports a real path as
---unresolvable — the false negative the whole feature exists to avoid. Leading wrappers
---(`(@src/init.lua`) stay excluded: `M.context` rejects them, and re-implementing its
---run-start scan to allow them would fork the grammar for a case that reads as text
---rather than as a broken path.
---@param line string
---@return AgentComplete.Token[]
function M.tokens(line)
  local out = {}
  for s, e in line:gmatch "()%S+()" do
    local last = e - 1 -- doubles as a 1-based index into `line` and a 0-based end column
    while last > s and line:find("^[%.,;:!?)%]}]", last) do
      last = last - 1
    end
    local ctx = M.context(line, last)
    if ctx then
      out[#out + 1] = { trigger = ctx.trigger, name = ctx.query, col = s - 1, end_col = last }
    end
  end
  return out
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
    -- Skills and commands share the `/` namespace, so one `seen` set spans both: the first
    -- entry for a name wins and every later one — skill or command — is dropped.
    -- Filesystem-scanned skills (instant) come first, then any tool-specific extra_skills
    -- (e.g. OpenCode's CLI-resolved set).
    local seen = {}
    local function add_skill(s)
      if seen[s.name] then
        return
      end
      seen[s.name] = true
      if matches(s.name, ctx.query) then
        table.insert(out, { label = "/" .. s.name, insert_text = s.name, kind = "skill", detail = s.description })
      end
    end
    for _, s in ipairs(scan.skills(session.skill_dirs, session.skill_namespaces)) do
      add_skill(s)
    end
    for _, s in ipairs(session.extra_skills or {}) do
      add_skill(s)
    end
    -- Markdown commands (from command_dirs, instant), then the tool CLI's resolved set
    -- (`cli_commands`, which alone sees plugin-contributed commands), then the remaining
    -- tool-specific ones (`extra_commands`: config-map and static built-ins). De-duplicated by
    -- name across all three, first wins — so a real command outranks a same-named static
    -- built-in, whose hard-coded description and `hidden` flag are the weakest source.
    local function add_command(c)
      if seen[c.name] then
        return
      end
      seen[c.name] = true
      if c.hidden and not session.show_all_builtin_commands then
        return
      end
      if matches(c.name, ctx.query) then
        table.insert(out, { label = "/" .. c.name, insert_text = c.name, kind = "command", detail = c.description })
      end
    end
    for _, list in ipairs {
      scan.commands(session.command_dirs),
      session.cli_commands or {},
      session.extra_commands or {},
    } do
      for _, c in ipairs(list) do
        add_command(c)
      end
    end
  elseif ctx.trigger == "@" and enabled.file ~= false then
    local function add_path(path, kind)
      if matches(path, ctx.query) then
        -- The space ends the token, so accepting a folder doesn't reopen the menu on its `/`.
        local insert_text = kind == "folder" and path .. " " or path
        table.insert(out, { label = "@" .. path, insert_text = insert_text, kind = kind })
      end
    end
    -- Folders first, as the native menu keeps this order; blink ranks via `score_offset` instead.
    local files = scan.files(session.cwd)
    for _, d in ipairs(scan.folders(session.cwd, files)) do
      add_path(d, "folder")
    end
    for _, f in ipairs(files) do
      add_path(f, "file")
    end
  end
  return out
end

return M
