---Async resolver for OpenCode's authoritative skill list via `opencode debug skill`.
---
---The filesystem scan in `scan.opencode_dirs` only sees skills under OpenCode's own config
---dirs; OpenCode itself resolves more (built-ins, `~/.claude/skills`, deeply nested
---`**/SKILL.md`). `opencode debug skill` prints the resolved set as JSON. This module runs it
---once per project cwd, asynchronously (`vim.system`), caches the parsed result, and hands it
---to the OpenCode detector as `session.extra_skills`. Reads are synchronous and never block:
---`get` returns whatever is cached now — an empty list while the job is pending or if it failed
---— so the editor is never delayed and a missing/broken `opencode` simply yields no extra
---skills. The `spawn`/`system` seams are dependency-injected in tests (the same pattern
---`backends/blink.lua` uses), so no real subprocess runs there.
---@class AgentComplete.OpenCodeSkills
local M = {}

---Per-cwd cache: `cwd -> { started: boolean, skills: AgentComplete.Skill[] }`.
---@type table<string, { started: boolean, skills: AgentComplete.Skill[] }>
M._cache = {}

---Parse `opencode debug skill` JSON — an array of `{name, description, location, content}` —
---into skills. Returns nil when the payload is not valid JSON; a valid non-array payload (or an
---array with no usable entries) yields an empty list. Entries without a string `name` are
---skipped; duplicates are retained (de-duplication happens downstream in `sources.items`).
---@param stdout string
---@return AgentComplete.Skill[]|nil
function M.parse(stdout)
  local ok, data = pcall(vim.json.decode, stdout)
  if not ok then
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

---Store parsed skills on `entry` when the command exited cleanly with output. A non-zero exit
---or empty stdout leaves the cache untouched (fail closed to the empty list it already holds).
---@param entry { started: boolean, skills: AgentComplete.Skill[] }
---@param obj { code: integer, stdout: string? }
function M._on_exit(entry, obj)
  if obj.code == 0 and obj.stdout and obj.stdout ~= "" then
    entry.skills = M.parse(obj.stdout) or {}
  end
end

---Kick off the async `opencode debug skill` job for `cwd`, writing results into `entry`.
---`pcall`-guarded so a missing `opencode` (or any spawn error) never raises into the editor.
---@param cwd string
---@param entry { started: boolean, skills: AgentComplete.Skill[] }
---@param system? fun(cmd: string[], opts: table, on_exit: fun(obj: table)): any Defaults to `vim.system`; injected in tests.
function M._spawn(cwd, entry, system)
  system = system or vim.system
  pcall(
    system,
    { "opencode", "debug", "skill" },
    { text = true, cwd = cwd, timeout = 5000 },
    vim.schedule_wrap(function(obj)
      M._on_exit(entry, obj)
    end)
  )
end

---Resolved skills for `cwd`. Lazily starts one background job per cwd (at most once) and returns
---whatever is cached now — an empty list while the job is pending or if it failed.
---@param cwd string
---@param spawn? fun(cwd: string, entry: table) Defaults to `M._spawn`; injected in tests.
---@return AgentComplete.Skill[]
function M.get(cwd, spawn)
  spawn = spawn or M._spawn
  local entry = M._cache[cwd]
  if not entry then
    entry = { started = false, skills = {} }
    M._cache[cwd] = entry
  end
  if not entry.started then
    entry.started = true
    spawn(cwd, entry)
  end
  return entry.skills
end

return M
