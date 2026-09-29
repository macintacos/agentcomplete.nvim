---OpenCode's last-assistant-message resolver.
---
---OpenCode serves its conversations through `opencode api`, but the external editor it spawns
---inherits no session id. So the session is resolved down three rungs — an exported id, a pointer
---file the OpenCode plugin's TUI half writes for its own pid, then a guess at the newest session
---in the cwd — and the rung that answered is reported alongside the message, because a guess
---shown as a certainty is worse than no pane.
---
---The pointer root, the subprocesses and the clock are optional `opts` seams (the pattern
---`agentcomplete.opencode_cli` uses), so tests touch no real `$HOME`, `ps`, or server.
local M = { name = "opencode" }

---Assistant messages fetched per read, newest first. The one shown is the newest carrying text,
---so a turn ending in more tool-only steps than this shows nothing.
local MESSAGE_PAGE = 20

---`ps -o etime=` output — POSIX `[[dd-]hh:]mm:ss` — as seconds. macOS `ps` has no `etimes`
---keyword, and `lstart` is a locale-formatted date Lua has no `strptime` for.
---@param s string
---@return integer|nil
function M.parse_etime(s)
  local days, clock = vim.trim(s):match("^(%d+)%-(.+)$")
  local fields = vim.split(clock or vim.trim(s), ":", { plain = true })
  if #fields < 2 or #fields > 3 then
    return nil
  end
  local seconds = 0
  for _, field in ipairs(fields) do
    local value = field:match("^%d+$") and tonumber(field)
    if not value then
      return nil
    end
    seconds = seconds * 60 + value
  end
  return seconds + (tonumber(days) or 0) * 86400
end

---The text of the newest assistant message in a `session.message.list` response (newest first)
---that carries any. Anchoring on that message rather than on every text part is what walks back
---past tool-only steps instead of returning the whole conversation.
---@param payload any
---@return string|nil
function M.message_text(payload)
  local messages = type(payload) == "table" and payload.data
  for _, message in ipairs(type(messages) == "table" and messages or {}) do
    local parts = {}
    for _, part in ipairs(type(message) == "table" and message.content or {}) do
      if
        type(part) == "table"
        and part.type == "text"
        and type(part.text) == "string"
        and vim.trim(part.text) ~= ""
      then
        parts[#parts + 1] = part.text
      end
    end
    if #parts > 0 then
      return table.concat(parts, "\n\n")
    end
  end
  return nil
end

---The root session in a `session.list` response used most recently at or after `since`. Ordered
---and floored on `time.updated`, not `time.created`: `opencode --continue` shows a session far
---older than the process showing it, which a creation floor hides outright.
---@param payload any
---@param since integer Epoch ms.
---@return string|nil
function M.newest_session(payload, since)
  local sessions = type(payload) == "table" and payload.data
  local best, best_updated
  for _, s in ipairs(type(sessions) == "table" and sessions or {}) do
    local updated = type(s) == "table" and type(s.time) == "table" and s.time.updated
    if
      type(updated) == "number"
      and type(s.id) == "string"
      and not s.parentID
      and updated >= since
      and (not best_updated or updated > best_updated)
    then
      best, best_updated = s.id, updated
    end
  end
  return best
end

---Where the OpenCode plugin records which session each TUI is showing.
---@param state_root? string
---@return string
function M.pointer_dir(state_root)
  local xdg = vim.env.XDG_STATE_HOME
  local state = state_root
    or ((xdg and xdg ~= "") and xdg or vim.fs.normalize("~/.local/state"))
  return state .. "/opencode/agentcomplete"
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

---The session the TUI's pointer names; false when it says the TUI is showing none, nil when there
---is no pointer to trust. `dispose` unlinks it only on a clean exit and pids are recycled, so a
---record older than the TUI — which every record it wrote postdates — is one a crashed
---predecessor left behind.
---@param tui_pid integer
---@param since integer Epoch ms the TUI started.
---@param state_root? string
---@return string|false|nil
local function pointed_session(tui_pid, since, state_root)
  local record = require("agentcomplete.context.proc").read_json(
    M.pointer_dir(state_root) .. "/" .. tui_pid .. ".json"
  ) or {}
  -- `etime` counts whole seconds, so `since` can land up to one after a pointer written at boot.
  if type(record.ts) ~= "number" or record.ts < since - 1000 then
    return nil
  end
  return type(record.sessionID) == "string" and record.sessionID or false
end

---@alias AgentComplete.Context.OpenCode.Api fun(args: string[], cb: fun(data: any|nil, err: string|nil))

---Resolve the session this prompt belongs to and hand `done` its id and rung, or nil, the rung
---that was being attempted, and why it failed.
---@param env { session_id: string|nil, tui_pid: integer|nil }
---@param cwd string
---@param opts AgentComplete.Context.OpenCode.Seams
---@param api AgentComplete.Context.OpenCode.Api
---@param done fun(id: string|nil, rung: string, err: string|nil)
local function find_session(env, cwd, opts, api, done)
  if env.session_id and env.session_id ~= "" then
    return done(env.session_id, "$OPENCODE_SESSION_ID")
  end
  local since =
    tui_start_ms(env.tui_pid, opts.system or vim.fn.system, opts.now or function()
      return os.time() * 1000
    end)
  if not since then
    return done(
      nil,
      "guessed",
      "no session id, and no OpenCode TUI to date a pointer or guess by"
    )
  end
  local pointed = pointed_session(env.tui_pid, since, opts.state_root)
  if pointed ~= nil then
    return done(pointed or nil, "pointer file", "the TUI is showing no session")
  end
  api(
    { "session.list", "--param", "directory=" .. cwd, "--param", "parentID=null" },
    function(payload, err)
      if payload == nil then
        return done(nil, "guessed", err)
      end
      local id = M.newest_session(payload, since)
      done(
        id,
        "guessed",
        not id and ("no session in " .. cwd .. " used since the TUI started") or nil
      )
    end
  )
end

---Report a failure. The session is still claimed: the walk got far enough to know it is ours,
---and handing it to the next resolver would only produce a second, less relevant error. The
---rung rides along too, so the diagnostics row can say which resolution was attempted.
---@param cb fun(result: AgentComplete.Context.Result)
---@param err string
---@param rung? string
local function fail(cb, err, rung)
  cb({ ok = false, resolver = M.name, rung = rung, err = err })
end

---@class AgentComplete.Context.OpenCode.Seams
---@field state_root? string Root the pointer directory hangs under; defaults to `$XDG_STATE_HOME` or `~/.local/state`.
---@field api? AgentComplete.Context.OpenCode.Api Async `opencode api`; defaults to `agentcomplete.opencode_cli.api`.
---@field system? fun(cmd: string[]): string Blocking `ps`; defaults to `vim.fn.system`.
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
  local api = opts.api or require("agentcomplete.opencode_cli").api
  -- Read here and nowhere below, so the rungs take what they need as arguments.
  local env = { session_id = vim.env.OPENCODE_SESSION_ID, tui_pid = session.agent_pid }
  -- Normalized because it may have been typed by the user via `$AGENTCOMPLETE_CWD`, while every
  -- directory it is compared against was recorded by OpenCode.
  local cwd = vim.fs.normalize(session.cwd)

  find_session(env, cwd, opts, api, function(id, rung, find_err)
    if not id then
      return fail(cb, find_err or "no session", rung)
    end
    api({
      "session.message.list",
      "--param",
      "sessionID=" .. id,
      "--param",
      "type=assistant",
      "--param",
      "order=desc",
      "--param",
      "limit=" .. MESSAGE_PAGE,
    }, function(payload, err)
      if payload == nil then
        return fail(cb, err or "no response", rung)
      end
      local text = M.message_text(payload)
      if not text then
        -- Named by rung, because on a guess the session may be one with nothing to show yet.
        return fail(
          cb,
          "no assistant message for the " .. rung .. " session " .. id,
          rung
        )
      end
      session.session_id = id
      cb({ ok = true, resolver = M.name, rung = rung, text = text, session_id = id })
    end)
  end)
  return true
end

return M
