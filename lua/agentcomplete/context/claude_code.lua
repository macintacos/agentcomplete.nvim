---Claude Code's last-assistant-message resolver.
---
---Claude Code records the live session at `~/.claude/sessions/<pid>.json` and the
---conversation at `~/.claude/projects/<slug>/<sessionId>.jsonl`. The external editor does
---not inherit the session id, so the walk starts from Neovim's parent pid and climbs until
---it finds the session file — an `$EDITOR` wrapper puts Claude Code a hop or two above.
---
---The roots and the subprocess are optional trailing parameters (the seam
---`agentcomplete.opencode_cli` uses), so tests read fixtures and never spawn `ps`.
local M = { name = "claude-code" }

local uv = vim.loop
local proc = require "agentcomplete.context.proc"

local MAX_PID_HOPS = 5

---Transcripts are large (hundreds of KB) and their final turns are tool calls, so the newest
---text block routinely sits well back from the end. Read a tail that doubles from here until
---it yields a message, reaches the start of the file, or hits the cap.
local TAIL_START = 256 * 1024
local TAIL_MAX = 4 * 1024 * 1024

---Climb from Neovim's parent to the first process Claude Code wrote a session file for.
---@param sessions_root string
---@param system fun(cmd: string[]): string
---@return string|nil path
local function session_file(sessions_root, system)
  local pid = uv.os_getppid() ---@type integer|nil
  for _ = 1, MAX_PID_HOPS do
    if not pid then
      return nil
    end
    local path = sessions_root .. "/" .. pid .. ".json"
    if uv.fs_stat(path) then
      return path
    end
    pid = proc.parent_pid(pid, system)
  end
  return nil
end

---The non-empty `text` blocks of one transcript entry, joined; nil when it carries none
---(a tool-call-only turn).
---@param entry table
---@return string|nil
local function entry_text(entry)
  local content = type(entry.message) == "table" and entry.message.content or nil
  if type(content) ~= "table" then
    return nil
  end
  local parts = {}
  for _, block in ipairs(content) do
    local text = type(block) == "table" and block.type == "text" and block.text or nil
    if type(text) == "string" and vim.trim(text) ~= "" then
      parts[#parts + 1] = text
    end
  end
  return #parts > 0 and table.concat(parts, "\n\n") or nil
end

---The newest main-thread assistant message in `lines`, scanning backwards.
---Lines are JSON-decoded rather than pattern-matched: `tool_result` payloads routinely embed
---the literal `"type":"assistant"` inside a nested string, which a match reads as a real entry.
---@param lines string[]
---@return string|nil
local function newest_message(lines)
  for i = #lines, 1, -1 do
    local ok, entry = pcall(vim.json.decode, lines[i])
    if ok and type(entry) == "table" and entry.type == "assistant" and entry.isSidechain ~= true then
      local text = entry_text(entry)
      if text then
        return text
      end
    end
  end
  return nil
end

---Scan `path` backwards over a growing tail, dropping the truncated line every chunk that
---starts mid-file opens on. The read begins one byte early so that leading fragment always
---exists: landing exactly on a newline would otherwise make the first line a complete one,
---and discarding it would throw away a real entry.
---@param path string
---@return string|nil
local function scan_backwards(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local size = (uv.fs_fstat(fd) or {}).size or 0
  local tail_size, message = TAIL_START, nil
  while true do
    local offset = math.max(0, size - tail_size)
    local from = offset > 0 and offset - 1 or 0
    local chunk = uv.fs_read(fd, size - from, from) or ""
    if from > 0 then
      chunk = chunk:sub((chunk:find("\n", 1, true) or #chunk) + 1)
    end
    message = newest_message(vim.split(chunk, "\n", { trimempty = true }))
    if message or offset == 0 or tail_size >= TAIL_MAX then
      break
    end
    tail_size = math.min(tail_size * 2, TAIL_MAX)
  end
  uv.fs_close(fd)
  return message
end

---Report a failure. The session is still claimed: the walk got far enough to know it is ours,
---and handing it to the next resolver would only produce a second, less relevant error.
---@param cb fun(result: AgentComplete.Context.Result)
---@param err string
---@return true
local function fail(cb, err)
  cb { ok = false, resolver = M.name, err = err }
  return true
end

---@param session AgentComplete.Session
---@param cb fun(result: AgentComplete.Context.Result)
---@param opts? { sessions_root?: string, projects_root?: string, system?: fun(cmd: string[]): string }
---@return true|nil claimed
function M.resolve(session, cb, opts)
  if session.tool ~= M.name then
    return nil
  end
  opts = opts or {}
  local system = opts.system or vim.fn.system
  local sessions_root = opts.sessions_root or vim.fs.normalize "~/.claude/sessions"
  local projects_root = opts.projects_root or vim.fs.normalize "~/.claude/projects"

  local pointer_path = session_file(sessions_root, system)
  if not pointer_path then
    return fail(cb, "no session file under " .. sessions_root .. " for this process tree")
  end
  -- `sessionId`, not the `session_id` that sits beside it in transcript entries: the two hold
  -- different values, and only `sessionId` names the session file and the transcript.
  local session_id = (proc.read_json(pointer_path) or {}).sessionId
  if type(session_id) ~= "string" then
    return fail(cb, "no sessionId in " .. pointer_path)
  end
  session.session_id = session_id

  local transcript = vim.fn.glob(projects_root .. "/*/" .. session_id .. ".jsonl", true, true)[1]
  if not transcript then
    return fail(cb, "no transcript for session " .. session_id .. " under " .. projects_root)
  end
  local text = scan_backwards(transcript)
  if not text then
    return fail(cb, "no assistant message in " .. transcript)
  end
  cb { ok = true, resolver = M.name, text = text, session_id = session_id, transcript = transcript }
  return true
end

return M
