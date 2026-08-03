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

---On a clean exit, read the temp file the command wrote and store the parsed skills on
---`entry`; the temp file is always removed. A non-zero exit or an unreadable/invalid file
---leaves the cache untouched (fail closed to the empty list it already holds).
---@param entry { started: boolean, skills: AgentComplete.Skill[] }
---@param obj { code: integer }
---@param path string Temp file the command's stdout was redirected to.
function M._on_exit(entry, obj, path)
  if obj.code == 0 then
    local ok, lines = pcall(vim.fn.readfile, path)
    local parsed = ok and M.parse(table.concat(lines, "\n"))
    if parsed then
      -- Mutate the existing list in place rather than reassigning, so a caller that captured
      -- the reference from `get` (the native backend caches its session once at attach) observes
      -- the resolved skills without re-fetching. Invalid output leaves the empty list untouched.
      for i = #entry.skills, 1, -1 do
        entry.skills[i] = nil
      end
      vim.list_extend(entry.skills, parsed)
      -- Observing the new skills is not enough: highlighting repaints on the attached
      -- buffer's own events, so this is the one moment resolution changes without one. The
      -- repaint is driven from here rather than from `highlight.lua`, which knows nothing
      -- about async backends. No debounce — `_on_exit` fires once per cwd, already inside
      -- `_spawn`'s `vim.schedule_wrap`. `pcall`ed like every other outward call here, so a
      -- raise cannot escape a `vim.system` callback or skip the temp-file delete below.
      pcall(require("agentcomplete.highlight").repaint_all)
    end
  end
  pcall(vim.fn.delete, path)
end

---Kick off the async `opencode debug skill` job for `cwd`, writing results into `entry`.
---`opencode`'s Bun/Node runtime does non-blocking writes to a pipe and truncates large output
---(~64KB) when read through one, so stdout is redirected to a temp file the callback reads
---instead. `pcall`-guarded so a missing `opencode`/`sh` (or any spawn error) never raises into
---the editor.
---@param cwd string
---@param entry { started: boolean, skills: AgentComplete.Skill[] }
---@param system? fun(cmd: string[], opts: table, on_exit: fun(obj: table)): any Defaults to `vim.system`; injected in tests.
function M._spawn(cwd, entry, system)
  system = system or vim.system
  local path = vim.fn.tempname()
  pcall(
    system,
    { "sh", "-c", "opencode debug skill > " .. vim.fn.shellescape(path) },
    { cwd = cwd, timeout = 5000 },
    vim.schedule_wrap(function(obj)
      M._on_exit(entry, obj, path)
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
