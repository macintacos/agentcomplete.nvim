-- Tests for agentcomplete.opencode_cli: pure JSON parsing of `opencode debug skill` and
-- `opencode debug config` output plus the lazy per-cwd async cache (with the subprocess injected).
local MiniTest = require "mini.test"
local new_set = MiniTest.new_set
local expect = MiniTest.expect

-- Reload the module fresh for each case so its cache resets.
local T = new_set {
  hooks = {
    pre_case = function()
      package.loaded["agentcomplete.opencode_cli"] = nil
    end,
    -- `highlight` is not reloaded between cases, so a buffer the repaint cases attached
    -- would otherwise outlive its own — with a live augroup and a `_sessions` entry — for
    -- the rest of the run. A hook rather than inline teardown because a failing `expect`
    -- raises past inline cleanup, which is exactly when the leak matters.
    post_case = function()
      local highlight = require "agentcomplete.highlight"
      for buf in pairs(highlight._sessions) do
        highlight.detach(buf)
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
    end,
  },
}

-- A representative `opencode debug skill` payload: a built-in (no path, no
-- description) and a duplicated name (dedup happens downstream in `sources`).
local SKILLS = table.concat({
  "[",
  '  {"name":"alpha","description":"A","location":"/x/alpha/SKILL.md","content":"# Alpha"},',
  '  {"name":"beta","location":"<built-in>"},',
  '  {"name":"alpha","description":"dup","location":"/y/alpha/SKILL.md"}',
  "]",
}, "\n")

-- A representative `opencode debug config` payload: the resolved config, of which only the
-- `command` map matters here. `zeta` is out of alphabetical order and `gamma` carries no
-- description, the two shapes the parser has to normalize.
local CONFIG = table.concat({
  "{",
  '  "model": "some/model",',
  '  "command": {',
  '    "zeta": {"description":"Z","template":"# Z"},',
  '    "gamma": {"template":"# G"}',
  "  }",
  "}",
}, "\n")

T["parse_skills"] = new_set()

T["parse_skills"]["maps name, description, and location -> path"] = function()
  local oc = require "agentcomplete.opencode_cli"
  local skills = assert(oc.parse_skills(SKILLS))
  expect.equality(#skills, 3) -- duplicate retained; dedup is downstream
  expect.equality(skills[1].name, "alpha")
  expect.equality(skills[1].description, "A")
  expect.equality(skills[1].path, "/x/alpha/SKILL.md")
end

T["parse_skills"]["a missing description becomes nil; a built-in keeps its location"] = function()
  local oc = require "agentcomplete.opencode_cli"
  local skills = assert(oc.parse_skills(SKILLS))
  expect.equality(skills[2].name, "beta")
  expect.equality(skills[2].description, nil)
  expect.equality(skills[2].path, "<built-in>")
end

T["parse_skills"]["invalid JSON returns nil"] = function()
  local oc = require "agentcomplete.opencode_cli"
  expect.equality(oc.parse_skills "not json{", nil)
end

T["parse_skills"]["a JSON object (non-array) yields an empty list"] = function()
  local oc = require "agentcomplete.opencode_cli"
  expect.equality(oc.parse_skills '{"foo":1}', {})
end

T["parse_skills"]["entries without a string name are skipped"] = function()
  local oc = require "agentcomplete.opencode_cli"
  expect.equality(oc.parse_skills '[{"description":"no name"}]', {})
end

T["parse_commands"] = new_set()

T["parse_commands"]["reads the resolved command map, sorted, with descriptions"] = function()
  local oc = require "agentcomplete.opencode_cli"
  local cmds = assert(oc.parse_commands(CONFIG))
  expect.equality(#cmds, 2)
  expect.equality(cmds[1].name, "gamma") -- sorted, so not the `pairs` order
  expect.equality(cmds[1].description, nil)
  expect.equality(cmds[2].name, "zeta")
  expect.equality(cmds[2].description, "Z")
end

-- The whole point of this probe: OpenCode resolves plugin-contributed commands from its package
-- cache, which no config-dir scan reaches, so they arrive only through the resolved config.
T["parse_commands"]["surfaces a plugin-contributed, namespaced command"] = function()
  local oc = require "agentcomplete.opencode_cli"
  local cmds = assert(oc.parse_commands '{"command":{"caret:debug":{"description":"D"}}}')
  expect.equality(cmds[1].name, "caret:debug")
  expect.equality(cmds[1].description, "D")
end

T["parse_commands"]["invalid JSON returns nil"] = function()
  local oc = require "agentcomplete.opencode_cli"
  expect.equality(oc.parse_commands "not json{", nil)
end

T["parse_commands"]["a config with no command map yields an empty list"] = function()
  local oc = require "agentcomplete.opencode_cli"
  expect.equality(oc.parse_commands '{"model":"x"}', {})
end

T["get"] = new_set()

T["get"]["spawns once per cwd and returns the empty cache while pending"] = function()
  local oc = require "agentcomplete.opencode_cli"
  local calls = 0
  local spawn = function()
    calls = calls + 1
  end
  local a = oc.get("/proj", spawn)
  local b = oc.get("/proj", spawn)
  expect.equality(calls, 1) -- guarded: at most one spawn per cwd
  expect.equality(a.skills, {}) -- empty while the jobs are pending
  expect.equality(a.commands, {})
  expect.equality(b.skills, {})
end

T["get"]["returns a pre-seeded cache verbatim without spawning"] = function()
  local oc = require "agentcomplete.opencode_cli"
  local spawned = false
  local spawn = function()
    spawned = true
  end
  oc._cache["/proj"] = { started = true, skills = { { name = "x" } }, commands = { { name = "c" } } }
  local got = oc.get("/proj", spawn)
  expect.equality(got.skills[1].name, "x")
  expect.equality(got.commands[1].name, "c")
  expect.equality(spawned, false)
end

T["on_exit"] = new_set()

---An entry as `get` would hand out, plus the probe row for `field`.
local function entry_and_probe(oc, field)
  local probe
  for _, p in ipairs(oc.probes) do
    if p.field == field then
      probe = p
    end
  end
  return { started = true, skills = {}, commands = {} }, assert(probe, "no probe for field " .. field)
end

---A temp file holding `payload`, as the spawned command's redirected stdout.
local function stdout_file(payload)
  local path = vim.fn.tempname()
  vim.fn.writefile(vim.split(payload, "\n"), path)
  return path
end

T["on_exit"]["populates the probe's list in place on a clean exit"] = function()
  local oc = require "agentcomplete.opencode_cli"
  local entry, probe = entry_and_probe(oc, "skills")
  local captured = entry.skills -- a caller (e.g. the native backend's cached session) holding the ref
  oc._on_exit(entry, { code = 0 }, stdout_file(SKILLS), probe)
  expect.equality(#entry.skills, 3)
  expect.equality(captured == entry.skills, true) -- mutated in place, not replaced, so the ref stays live
end

-- Each probe fills only its own field, so a config payload must not disturb the skills list
-- (and vice versa) — the two jobs land independently and in no guaranteed order.
T["on_exit"]["the commands probe fills commands and leaves skills alone"] = function()
  local oc = require "agentcomplete.opencode_cli"
  local entry, probe = entry_and_probe(oc, "commands")
  local captured = entry.commands
  oc._on_exit(entry, { code = 0 }, stdout_file(CONFIG), probe)
  expect.equality(#entry.commands, 2)
  expect.equality(entry.skills, {})
  expect.equality(captured == entry.commands, true)
end

T["on_exit"]["leaves the list empty on a non-zero exit"] = function()
  local oc = require "agentcomplete.opencode_cli"
  local entry, probe = entry_and_probe(oc, "skills")
  oc._on_exit(entry, { code = 1 }, vim.fn.tempname(), probe)
  expect.equality(entry.skills, {})
end

---The extmarks actually applied to `buf`, in `highlight.marks` shape.
local function painted(buf)
  local ns = require("agentcomplete.highlight").ns
  return vim.tbl_map(function(m)
    return { row = m[2], col = m[3], end_col = m[4].end_col, hl_group = m[4].hl_group }
  end, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }))
end

---A scratch buffer holding `lines`, attached to a session whose `extra_skills`/`cli_commands`
---are `entry`'s lists — the references the OpenCode detector hands out before the jobs land.
local function attached_buf(entry, lines)
  local highlight = require "agentcomplete.highlight"
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  highlight.attach(buf, {
    tool = "opencode",
    cwd = vim.fn.tempname(),
    skill_dirs = {},
    command_dirs = {},
    extra_skills = entry.skills,
    cli_commands = entry.commands,
  })
  return buf
end

-- The items arrive after attach, so no buffer event repaints them: without an explicit
-- repaint the token stays uncolored, which is this plugin's signal for "does not resolve".
T["on_exit"]["repaints attached buffers so late-resolved skills paint"] = function()
  local oc = require "agentcomplete.opencode_cli"
  local entry, probe = entry_and_probe(oc, "skills")
  local buf = attached_buf(entry, { "/alpha" })
  expect.equality(painted(buf), {}) -- pending: nothing resolves yet

  oc._on_exit(entry, { code = 0 }, stdout_file(SKILLS), probe)
  expect.equality(painted(buf), { { row = 0, col = 0, end_col = 6, hl_group = "AgentCompleteSkill" } })
end

T["on_exit"]["repaints attached buffers so late-resolved commands paint"] = function()
  local oc = require "agentcomplete.opencode_cli"
  local entry, probe = entry_and_probe(oc, "commands")
  local buf = attached_buf(entry, { "/zeta" })
  expect.equality(painted(buf), {})

  oc._on_exit(entry, { code = 0 }, stdout_file(CONFIG), probe)
  expect.equality(painted(buf), { { row = 0, col = 0, end_col = 5, hl_group = "AgentCompleteSkill" } })
end

-- Only the exit code separates this from the case above — the payload is readable and
-- would resolve `/alpha` — so a repaint that ignored `obj.code` paints here and fails.
T["on_exit"]["a non-zero exit neither resolves nor paints"] = function()
  local oc = require "agentcomplete.opencode_cli"
  local entry, probe = entry_and_probe(oc, "skills")
  local buf = attached_buf(entry, { "/alpha" })
  oc._on_exit(entry, { code = 1 }, stdout_file(SKILLS), probe)
  expect.equality(painted(buf), {})
end

T["spawn"] = new_set()

T["spawn"]["runs one job per probe, each redirected to its own temp file"] = function()
  local oc = require "agentcomplete.opencode_cli"
  local cmds = {}
  local system = function(cmd)
    cmds[#cmds + 1] = cmd[3]
  end
  oc._spawn("/proj", { started = true, skills = {}, commands = {} }, system)
  expect.equality(#cmds, #oc.probes)
  expect.equality(cmds[1]:match "^opencode debug skill > " ~= nil, true)
  expect.equality(cmds[2]:match "^opencode debug config > " ~= nil, true)
  expect.equality(cmds[1] ~= cmds[2], true) -- distinct temp files; one job cannot clobber the other
end

T["spawn"]["a throwing system call is guarded: no error, lists stay empty"] = function()
  local oc = require "agentcomplete.opencode_cli"
  local throwing = function()
    error "ENOENT"
  end
  local entry = { started = true, skills = {}, commands = {} }
  oc._spawn("/proj", entry, throwing) -- must not raise
  expect.equality(entry.skills, {})
  expect.equality(entry.commands, {})
end

return T
