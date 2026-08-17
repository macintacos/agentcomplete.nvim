---Async resolver for OpenCode's authoritative skill and command sets via `opencode debug`.
---
---The filesystem scan in `scan.opencode_dirs` only sees skills and commands under OpenCode's
---own config dirs; OpenCode itself resolves more. For skills: built-ins, `~/.claude/skills`,
---deeply nested `**/SKILL.md`. For commands: every command contributed by an installed
---OpenCode plugin, which lives under `~/.cache/opencode/packages/**` and so is unreachable by
---any config-dir scan or `opencode.json[c]` read. Guessing at OpenCode's layout is what makes
---a command silently missing from completion; asking OpenCode is what makes new sources of
---skills and commands appear here for free.
---
---`opencode debug skill` prints the resolved skills as a JSON array; `opencode debug config`
---prints the resolved config, whose `command` map is the resolved command set. This module runs
---one job per probe per project cwd, asynchronously (`vim.system`), caches the parsed results,
---and hands them to the OpenCode detector as `session.extra_skills` / `session.cli_commands`.
---Reads are synchronous and never block: `get` returns whatever is cached now — empty lists
---while the jobs are pending or if they failed — so the editor is never delayed and a
---missing/broken `opencode` simply yields nothing extra. The `spawn`/`system` seams are
---dependency-injected in tests (the same pattern `backends/blink.lua` uses), so no real
---subprocess runs there.
---@class AgentComplete.OpenCodeCli
local M = {}

---@class AgentComplete.OpenCodeCli.Entry
---@field started boolean Whether the background jobs for this cwd have been kicked off.
---@field skills AgentComplete.Skill[] Resolved skills; empty until `opencode debug skill` lands.
---@field commands AgentComplete.Command[] Resolved commands; empty until `opencode debug config` lands.

---Per-cwd cache: `cwd -> AgentComplete.OpenCodeCli.Entry`.
---@type table<string, AgentComplete.OpenCodeCli.Entry>
M._cache = {}

---Decode a probe's stdout, returning nil when it is not valid JSON so the caller can fail
---closed (leaving the empty list it already holds) rather than clearing a good result.
---@param stdout string
---@return any|nil
local function decode(stdout)
  local ok, data = pcall(vim.json.decode, stdout)
  if not ok then
    return nil
  end
  return data
end

---Parse `opencode debug skill` JSON — an array of `{name, description, location, content}` —
---into skills. Returns nil when the payload is not valid JSON; a valid non-array payload (or an
---array with no usable entries) yields an empty list. Entries without a string `name` are
---skipped; duplicates are retained (de-duplication happens downstream in `sources.items`).
---@param stdout string
---@return AgentComplete.Skill[]|nil
function M.parse_skills(stdout)
  local data = decode(stdout)
  if data == nil then
    return nil
  end
  local out = {}
  if type(data) ~= "table" then
    return out
  end
  for _, item in ipairs(data) do
    if type(item) == "table" and type(item.name) == "string" and item.name ~= "" then
      local desc = type(item.description) == "string" and item.description or nil
      local loc = type(item.location) == "string" and item.location or nil
      out[#out + 1] = { name = item.name, description = desc, path = loc }
    end
  end
  return out
end

---Parse `opencode debug config` JSON — the fully resolved config — into commands, read from its
---`command` map (`name -> { description, template, … }`). Returns nil when the payload is not
---valid JSON; a payload without a `command` map yields an empty list, which is the honest answer
---for a session that has no commands. Names are sorted so completion order does not ride on Lua's
---`pairs` order. No `path` is reported: the resolved map records no source file, and nothing
---downstream needs one (built-in commands are already path-less).
---@param stdout string
---@return AgentComplete.Command[]|nil
function M.parse_commands(stdout)
  local data = decode(stdout)
  if data == nil then
    return nil
  end
  if type(data) ~= "table" or type(data.command) ~= "table" then
    return {}
  end
  local names = {}
  for name in pairs(data.command) do
    if type(name) == "string" and name ~= "" then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    local spec = data.command[name]
    local desc = type(spec) == "table" and type(spec.description) == "string" and spec.description or nil
    out[#out + 1] = { name = name, description = desc }
  end
  return out
end

---The `opencode debug` invocations to resolve, one per set. Adding a set is adding a row here:
---`field` is the `AgentComplete.OpenCodeCli.Entry` list it fills, `argv` the shell command, and
---`parse` the function turning its stdout into items.
---@type { field: string, argv: string, parse: fun(stdout: string): table[]|nil }[]
M.probes = {
  { field = "skills", argv = "opencode debug skill", parse = M.parse_skills },
  { field = "commands", argv = "opencode debug config", parse = M.parse_commands },
}

---On a clean exit, read the temp file the command wrote and store the parsed items in the
---`probe.field` list on `entry`; the temp file is always removed. A non-zero exit or an
---unreadable/invalid file leaves the cache untouched (fail closed to the empty list it
---already holds).
---@param entry AgentComplete.OpenCodeCli.Entry
---@param obj { code: integer }
---@param path string Temp file the command's stdout was redirected to.
---@param probe { field: string, parse: fun(stdout: string): table[]|nil }
function M._on_exit(entry, obj, path, probe)
  if obj.code == 0 then
    local ok, lines = pcall(vim.fn.readfile, path)
    local parsed = ok and probe.parse(table.concat(lines, "\n"))
    if parsed then
      -- Mutate the existing list in place rather than reassigning, so a caller that captured
      -- the reference from `get` (the native backend caches its session once at attach) observes
      -- the resolved items without re-fetching. Invalid output leaves the empty list untouched.
      local target = entry[probe.field]
      for i = #target, 1, -1 do
        target[i] = nil
      end
      vim.list_extend(target, parsed)
      -- Observing the new items is not enough: highlighting repaints on the attached buffer's
      -- own events, so this is the one moment resolution changes without one. The repaint is
      -- driven from here rather than from `highlight.lua`, which knows nothing about async
      -- backends. No debounce — each probe's `_on_exit` fires once per cwd, already inside
      -- `_spawn`'s `vim.schedule_wrap`. `pcall`ed like every other outward call here, so a
      -- raise cannot escape a `vim.system` callback or skip the temp-file delete below.
      pcall(require("agentcomplete.highlight").repaint_all)
    end
  end
  pcall(vim.fn.delete, path)
end

---Kick off one async `opencode debug …` job per probe for `cwd`, writing results into `entry`.
---`opencode`'s Bun/Node runtime does non-blocking writes to a pipe and truncates large output
---(~64KB) when read through one — which `opencode debug config` exceeds outright — so each
---stdout is redirected to a temp file the callback reads instead. `pcall`-guarded so a missing
---`opencode`/`sh` (or any spawn error) never raises into the editor.
---@param cwd string
---@param entry AgentComplete.OpenCodeCli.Entry
---@param system? fun(cmd: string[], opts: table, on_exit: fun(obj: table)): any Defaults to `vim.system`; injected in tests.
function M._spawn(cwd, entry, system)
  system = system or vim.system
  for _, probe in ipairs(M.probes) do
    local path = vim.fn.tempname()
    pcall(
      system,
      { "sh", "-c", probe.argv .. " > " .. vim.fn.shellescape(path) },
      { cwd = cwd, timeout = 5000 },
      vim.schedule_wrap(function(obj)
        M._on_exit(entry, obj, path, probe)
      end)
    )
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
