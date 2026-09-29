---Async access to OpenCode's running server through `opencode api`, and the skill and command
---sets resolved from it.
---
---The filesystem scan in `scan.opencode_dirs` only sees skills and commands under OpenCode's
---own config dirs; OpenCode itself resolves more. For skills: built-ins, `~/.claude/skills`,
---deeply nested `**/SKILL.md`. For commands: every command contributed by an installed
---OpenCode plugin, which lives under `~/.cache/opencode/packages/**` and so is unreachable by
---any config-dir scan or `opencode.json[c]` read. Guessing at OpenCode's layout is what makes
---a command silently missing from completion; asking OpenCode is what makes new sources of
---skills and commands appear here for free.
---
---`opencode api skill.list` / `command.list` answer for a location, so each is asked for the
---project cwd. This module runs one job per probe per cwd, asynchronously (`vim.system`), caches
---the parsed results, and hands them to the OpenCode detector as `session.extra_skills` /
---`session.cli_commands`. Reads are synchronous and never block: `get` returns whatever is cached
---now — empty lists while the jobs are pending or if they failed — so the editor is never delayed
---and a missing/broken `opencode` simply yields nothing extra. The `system` seams are
---dependency-injected in tests (the same pattern `backends/blink.lua` uses), so no real
---subprocess runs there.
---@class AgentComplete.OpenCodeCli
local M = {}

---@class AgentComplete.OpenCodeCli.Entry
---@field started boolean Whether the background jobs for this cwd have been kicked off.
---@field skills AgentComplete.Skill[] Resolved skills; empty until `skill.list` lands.
---@field commands AgentComplete.Command[] Resolved commands; empty until `command.list` lands.

---Per-cwd cache: `cwd -> AgentComplete.OpenCodeCli.Entry`.
---@type table<string, AgentComplete.OpenCodeCli.Entry>
M._cache = {}

---Read and remove `path`, the finished command's redirected stdout, and hand `cb` its decoded
---JSON — or nil and why not.
---@param obj { code: integer, stderr?: string }
---@param path string
---@param cb fun(data: any|nil, err: string|nil)
function M._on_exit(obj, path, cb)
  local read, lines = pcall(vim.fn.readfile, path)
  pcall(vim.fn.delete, path)
  if obj.code ~= 0 then
    return cb(
      nil,
      "opencode api exited " .. tostring(obj.code) .. ": " .. vim.trim(obj.stderr or "")
    )
  end
  local ok, data = pcall(vim.json.decode, table.concat(read and lines or {}, "\n"))
  if not ok then
    return cb(nil, "opencode api printed no JSON")
  end
  cb(data)
end

---Run `opencode api <args>` against the running server and hand `cb` the decoded response, or
---nil and a reason. `opencode`'s Bun runtime truncates large output (~64KB) read through a pipe —
---which `skill.list` exceeds outright — so stdout is redirected to a temp file read on exit.
---`pcall`-guarded so a missing `opencode`/`sh` never raises into the editor.
---@param args string[] Arguments after `opencode api`: an operation id and its `--param`s.
---@param cb fun(data: any|nil, err: string|nil)
---@param system? fun(cmd: string[], opts: table, on_exit: fun(obj: table)): any Defaults to `vim.system`; injected in tests.
function M.api(args, cb, system)
  system = system or vim.system
  local path = vim.fn.tempname()
  local argv = table.concat(vim.tbl_map(vim.fn.shellescape, args), " ")
  local started = pcall(
    system,
    { "sh", "-c", "opencode api " .. argv .. " > " .. vim.fn.shellescape(path) },
    { text = true, timeout = 5000 },
    vim.schedule_wrap(function(obj)
      M._on_exit(obj, path, cb)
    end)
  )
  if not started then
    cb(nil, "could not run opencode")
  end
end

---The `data` array of a list response, or an empty one when the payload has none.
---@param payload any
---@return table[]
local function rows(payload)
  local data = type(payload) == "table" and payload.data
  return type(data) == "table" and data or {}
end

---@param v any
---@return string|nil
local function str(v)
  return type(v) == "string" and v or nil
end

---Parse a `skill.list` response — `{ data = { {id, name, description, path, content} } }` — into
---skills named by `id`, which is what the TUI inserts (`name` is a display title, e.g. `OpenCode`
---for `opencode`). Entries without a string id are skipped; duplicates are retained
---(de-duplication happens downstream in `sources.items`).
---@param payload any
---@return AgentComplete.Skill[]
function M.parse_skills(payload)
  local out = {}
  for _, item in ipairs(rows(payload)) do
    if type(item) == "table" and str(item.id) and item.id ~= "" then
      out[#out + 1] =
        { name = item.id, description = str(item.description), path = str(item.path) }
    end
  end
  return out
end

---Parse a `command.list` response — `{ data = { {name, description} } }` — into commands. No
---`path` is reported: the response records no source file, and nothing downstream needs one.
---@param payload any
---@return AgentComplete.Command[]
function M.parse_commands(payload)
  local out = {}
  for _, item in ipairs(rows(payload)) do
    if type(item) == "table" and str(item.name) and item.name ~= "" then
      out[#out + 1] = { name = item.name, description = str(item.description) }
    end
  end
  return out
end

---The server operations to resolve, one per set. Adding a set is adding a row here: `field` is
---the `AgentComplete.OpenCodeCli.Entry` list it fills, `operation` the `opencode api` operation
---id, and `parse` the function turning its response into items.
---@type { field: string, operation: string, parse: fun(payload: any): table[] }[]
M.probes = {
  { field = "skills", operation = "skill.list", parse = M.parse_skills },
  { field = "commands", operation = "command.list", parse = M.parse_commands },
}

---Store a probe's parsed response in the `probe.field` list on `entry`. A failed request
---(`payload` nil) leaves the cache untouched, failing closed to the empty list it already holds.
---@param entry AgentComplete.OpenCodeCli.Entry
---@param probe { field: string, parse: fun(payload: any): table[] }
---@param payload any|nil
function M._fill(entry, probe, payload)
  if payload == nil then
    return
  end
  -- Mutate the existing list in place rather than reassigning, so a caller that captured the
  -- reference from `get` (the native backend caches its session once at attach) observes the
  -- resolved items without re-fetching.
  local target = entry[probe.field]
  for i = #target, 1, -1 do
    target[i] = nil
  end
  vim.list_extend(target, probe.parse(payload))
  -- Observing the new items is not enough: highlighting repaints on the attached buffer's own
  -- events, so this is the one moment resolution changes without one. The repaint is driven
  -- from here rather than from `highlight.lua`, which knows nothing about async backends. No
  -- debounce — each probe fills once per cwd, already inside `api`'s `vim.schedule_wrap`.
  -- `pcall`ed like every other outward call here, so a raise cannot escape a `vim.system`
  -- callback.
  pcall(require("agentcomplete.highlight").repaint_all)
end

---Kick off one async `opencode api` job per probe for `cwd`, writing results into `entry`.
---@param cwd string
---@param entry AgentComplete.OpenCodeCli.Entry
---@param system? fun(cmd: string[], opts: table, on_exit: fun(obj: table)): any Defaults to `vim.system`; injected in tests.
function M._spawn(cwd, entry, system)
  for _, probe in ipairs(M.probes) do
    M.api({ probe.operation, "--param", "location[directory]=" .. cwd }, function(payload)
      M._fill(entry, probe, payload)
    end, system)
  end
end

---Resolved skills and commands for `cwd`. Lazily starts the background jobs once per cwd and
---returns whatever is cached now — empty lists while a job is pending or if it failed. The
---returned lists are the live tables the jobs fill in place, so a caller may hold the reference.
---@param cwd string
---@param spawn? fun(cwd: string, entry: AgentComplete.OpenCodeCli.Entry) Defaults to `M._spawn`; injected in tests.
---@return AgentComplete.OpenCodeCli.Entry
function M.get(cwd, spawn)
  spawn = spawn or M._spawn
  local entry = M._cache[cwd]
  if not entry then
    entry = { started = false, skills = {}, commands = {} }
    M._cache[cwd] = entry
  end
  if not entry.started then
    entry.started = true
    spawn(cwd, entry)
  end
  return entry
end

return M
