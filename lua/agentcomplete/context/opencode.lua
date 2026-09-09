---OpenCode's last-assistant-message resolver.
---
---OpenCode keeps its conversations in a SQLite database at
---`~/.local/share/opencode/opencode.db` and persists no pid→session mapping, while the
---external editor inherits `OPENCODE_PID` but no session id. So the session is resolved down
---three rungs — an exported id, a pointer file the OpenCode plugin writes for this process
---tree, then a guess at the newest session in the cwd — and the rung that answered is reported
---alongside the message, because a guess shown as a certainty is worse than no pane.
---
---The roots, the subprocesses and the clock are optional `opts` seams (the pattern
---`agentcomplete.opencode_cli` uses), so tests touch no real `$HOME`, `ps`, or database.
local M = { name = "opencode" }

local uv = vim.loop
local proc = require "agentcomplete.context.proc"

local MAX_PID_HOPS = 5

---Bounds the read the way `opencode_cli` bounds its probes: a `sqlite3` that never exits would
---otherwise leave the pane silently absent and nothing in the log.
local SQLITE_TIMEOUT_MS = 5000

---`ps -o etime=` output — POSIX `[[dd-]hh:]mm:ss` — as seconds. macOS `ps` has no `etimes`
---keyword, and `lstart` is a locale-formatted date Lua has no `strptime` for.
---@param s string
---@return integer|nil
function M.parse_etime(s)
  local days, clock = vim.trim(s):match "^(%d+)%-(.+)$"
  local fields = vim.split(clock or vim.trim(s), ":", { plain = true })
  if #fields < 2 or #fields > 3 then
    return nil
  end
  local seconds = 0
  for _, field in ipairs(fields) do
    local value = field:match "^%d+$" and tonumber(field)
    if not value then
      return nil
    end
    seconds = seconds * 60 + value
  end
  return seconds + (tonumber(days) or 0) * 86400
end

---@param record table
---@param wanted table<integer, boolean>
---@return boolean
local function names_a_pid(record, wanted)
  for _, pid in ipairs(type(record.pids) == "table" and record.pids or {}) do
    if wanted[pid] then
      return true
    end
  end
  return false
end

---The pointer record for this process tree: one naming a pid in `chain` and `cwd` as either
---its `directory` or its `worktree`, freshest `ts` first. The directory check is what stops a
---recycled pid matching a record from another project, and `since` — the TUI's start time,
---which every record for it postdates — is what stops one a crash left behind, since `dispose`
---unlinks only on a clean exit.
---@param records table[]
---@param chain integer[] Pids this Neovim's tree runs under.
---@param cwd string
---@param since? integer Epoch ms before which a record cannot describe this process.
---@return table|nil
function M.pick_pointer(records, chain, cwd, since)
  local wanted = {}
  for _, pid in ipairs(chain) do
    wanted[pid] = true
  end
  local best
  for _, record in ipairs(records) do
    local ts = record.ts or 0
    if
      type(record.sessionID) == "string"
      and (not since or ts >= since)
      and (record.directory == cwd or record.worktree == cwd)
      and names_a_pid(record, wanted)
      and (not best or ts > (best.ts or 0))
    then
      best = record
    end
  end
  return best
end

---A SQL string literal: session ids and cwd paths are both interpolated into the query.
---@param s string
---@return string
local function quote(s)
  return "'" .. s:gsub("'", "''") .. "'"
end

---The parts of the newest assistant message in `session_expr` that carries non-empty text.
---Anchoring on that message rather than on every assistant text part is what walks back past
---tool-only turns instead of returning the whole conversation.
---@param session_expr string SQL yielding one session id.
---@return string
function M.message_sql(session_expr)
  return ([[
select json_extract(p.data, '$.text') as text, p.session_id as session_id
from part p
where p.message_id = (
    select p2.message_id from part p2
    join message m2 on m2.id = p2.message_id
    where m2.session_id = (%s)
      and json_extract(m2.data, '$.role') = 'assistant'
      and json_extract(p2.data, '$.type') = 'text'
      and trim(coalesce(json_extract(p2.data, '$.text'), '')) <> ''
    order by p2.time_created desc, p2.id desc
    limit 1)
  and json_extract(p.data, '$.type') = 'text'
order by p.time_created, p.id;]]):format(session_expr)
end

---The message `sqlite3 -json` returned, and the session it was read from. Nil when the output
---is not a result set or holds no text — an empty result prints nothing at all.
---@param json string
---@return string|nil text
---@return string|nil session_id
function M.join_rows(json)
  local ok, rows = pcall(vim.json.decode, json)
  if not ok or type(rows) ~= "table" then
    return nil
  end
  local parts, session_id
  for _, row in ipairs(rows) do
    if type(row) == "table" and type(row.text) == "string" and vim.trim(row.text) ~= "" then
      parts = parts or {}
      parts[#parts + 1] = row.text
      session_id = session_id or (type(row.session_id) == "string" and row.session_id or nil)
    end
  end
  return parts and table.concat(parts, "\n\n") or nil, session_id
end

---Where the OpenCode plugin records which session a process belongs to.
---@param state_root? string
---@return string
function M.pointer_dir(state_root)
  local xdg = vim.env.XDG_STATE_HOME
  local state = state_root or ((xdg and xdg ~= "") and xdg or vim.fs.normalize "~/.local/state")
  return state .. "/opencode/agentcomplete"
end

---Where OpenCode keeps its conversations.
---@param data_root? string
---@return string
function M.db_path(data_root)
  local xdg = vim.env.XDG_DATA_HOME
  local data = data_root or ((xdg and xdg ~= "") and xdg or vim.fs.normalize "~/.local/share")
  return data .. "/opencode/opencode.db"
end

---@param dir string
---@return table[]
local function pointer_records(dir)
  local out = {}
  for _, path in ipairs(vim.fn.glob(dir .. "/*.json", true, true)) do
    out[#out + 1] = proc.read_json(path)
  end
  return out
end

---`$OPENCODE_PID` and Neovim's own ancestors: the pids a pointer for this session may name.
---Recording all of them is what makes it not matter whether the plugin ran in the TUI process,
---an instance-server child, or the shared daemon.
---@param tui_pid integer|nil
---@param system fun(cmd: string[]): string
---@return integer[]
local function pid_chain(tui_pid, system)
  local chain = { tui_pid }
  local pid = uv.os_getppid() ---@type integer|nil
  for _ = 1, MAX_PID_HOPS do
    if not pid then
      break
    end
    chain[#chain + 1] = pid
    pid = proc.parent_pid(pid, system)
  end
  return chain
end

---When the TUI started, in epoch milliseconds, from its elapsed time.
---@param tui_pid integer|nil
---@param system fun(cmd: string[]): string
---@param now fun(): integer
---@return integer|nil
local function tui_start_ms(tui_pid, system, now)
  if not tui_pid then
    return nil
  end
  local ok, out = pcall(system, { "ps", "-o", "etime=", "-p", tostring(tui_pid) })
  local elapsed = ok and M.parse_etime(out or "")
  return elapsed and now() - elapsed * 1000 or nil
end

---The SQL naming this prompt's session, and which rung produced it.
---@param env { session_id: string|nil, tui_pid: integer|nil }
---@param cwd string
---@param opts AgentComplete.Context.OpenCode.Seams
---@return string|nil expr
---@return string rung
local function session_expr(env, cwd, opts)
  if env.session_id and env.session_id ~= "" then
    return quote(env.session_id), "$OPENCODE_SESSION_ID"
  end
  local system = opts.system or vim.fn.system
  local start_ms = tui_start_ms(env.tui_pid, system, opts.now or function()
    return os.time() * 1000
  end)

  local records = pointer_records(M.pointer_dir(opts.state_root))
  -- The pid climb forks `ps` up to `MAX_PID_HOPS` times at prompt-open, so it waits on there
  -- being anything for it to match against — which there is not until the plugin is installed.
  local pointer = #records > 0 and M.pick_pointer(records, pid_chain(env.tui_pid, system), cwd, start_ms)
  if pointer then
    return quote(pointer.sessionID), "pointer file"
  end

  if not start_ms then
    return nil, "guessed"
  end
  -- Ordered and floored on `time_updated`, not `time_created`: `opencode --continue` shows a
  -- session far older than the process showing it, which a creation floor hides outright.
  local newest_root = (
    "select id from session where parent_id is null and directory = %s"
    .. " and time_updated >= %d order by time_updated desc limit 1"
  ):format(quote(cwd), start_ms)
  return newest_root, "guessed"
end

---Report a failure. The session is still claimed: the walk got far enough to know it is ours,
---and handing it to the next resolver would only produce a second, less relevant error. The
---rung rides along so the diagnostics row says which resolution was being attempted — which is
---most of what a reader wants when the complaint is that no pane appeared at all.
---@param cb fun(result: AgentComplete.Context.Result)
---@param err string
---@param rung? string
---@return true
local function fail(cb, err, rung)
  cb { ok = false, resolver = M.name, rung = rung, err = err }
  return true
end

---@class AgentComplete.Context.OpenCode.Seams
---@field state_root? string Root the pointer directory hangs under; defaults to `$XDG_STATE_HOME` or `~/.local/state`.
---@field db_path? string OpenCode's database; defaults to `~/.local/share/opencode/opencode.db`.
---@field system? fun(cmd: string[]): string Blocking `ps`; defaults to `vim.fn.system`.
---@field spawn? fun(cmd: string[], opts: table, on_exit: fun(obj: table)): any Async `sqlite3`; defaults to `vim.system`.
---@field now? fun(): integer Current time in epoch milliseconds.

---@param session AgentComplete.Session
---@param cb fun(result: AgentComplete.Context.Result)
---@param opts? AgentComplete.Context.OpenCode.Seams
---@return true|nil claimed
function M.resolve(session, cb, opts)
  if session.tool ~= M.name then
    return nil
  end
  opts = opts or {}
  local db = opts.db_path or M.db_path()
  if not uv.fs_stat(db) then
    return fail(cb, "no OpenCode database at " .. db)
  end

  -- The environment is read here and nowhere below, so the rungs take what they need as
  -- arguments. `session.cwd` is normalized because it may have been typed by the user via
  -- `$AGENTCOMPLETE_CWD`, while every path it is compared against was written by OpenCode.
  local env = { session_id = vim.env.OPENCODE_SESSION_ID, tui_pid = tonumber(vim.env.OPENCODE_PID) }
  local cwd = vim.fs.normalize(session.cwd)

  local expr, rung = session_expr(env, cwd, opts)
  if not expr then
    return fail(cb, "no session id, no pointer file, and no $OPENCODE_PID to date a guess from", rung)
  end

  -- No temp-file redirect, unlike `opencode_cli`'s probes: that exists because `opencode`'s Bun
  -- runtime truncates large output through a pipe, and `sqlite3` is a plain C binary.
  local spawn = opts.spawn or vim.system
  local started = pcall(
    spawn,
    { "sqlite3", "-readonly", "-json", db, M.message_sql(expr) },
    { text = true, timeout = SQLITE_TIMEOUT_MS },
    vim.schedule_wrap(function(obj)
      if obj.code ~= 0 then
        return fail(cb, "sqlite3 exited " .. tostring(obj.code) .. ": " .. vim.trim(obj.stderr or ""), rung)
      end
      local text, session_id = M.join_rows(obj.stdout or "")
      if not text then
        -- Named by rung, because on the guess the sub-select may have matched no session at
        -- all — which sends a reader hunting for a missing message rather than a missing one.
        return fail(cb, "no assistant message for the " .. rung .. " session in " .. db, rung)
      end
      session.session_id = session_id or session.session_id
      cb { ok = true, resolver = M.name, rung = rung, text = text, session_id = session_id, transcript = db }
    end)
  )
  if not started then
    return fail(cb, "could not run sqlite3", rung)
  end
  return true
end

return M
