-- Tests for agentcomplete.opencode_cli: the `opencode api` runner, parsing of its `skill.list`
-- and `command.list` payloads, and the lazy per-cwd async cache (with the subprocess injected).
local MiniTest = require("mini.test")
local new_set = MiniTest.new_set
local expect = MiniTest.expect

-- Reload the module fresh for each case so its cache resets.
local T = new_set({
  hooks = {
    pre_case = function()
      package.loaded["agentcomplete.opencode_cli"] = nil
    end,
    -- `highlight` is not reloaded between cases, so a buffer the repaint cases attached
    -- would otherwise outlive its own — with a live augroup and a `_sessions` entry — for
    -- the rest of the run. A hook rather than inline teardown because a failing `expect`
    -- raises past inline cleanup, which is exactly when the leak matters.
    post_case = function()
      local highlight = require("agentcomplete.highlight")
      for buf in pairs(highlight._sessions) do
        highlight.detach(buf)
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
    end,
  },
})

-- A representative `opencode api skill.list` payload: a built-in whose display `name` differs
-- from the `id` the TUI inserts, and a duplicated id (dedup happens downstream in `sources`).
local SKILLS = {
  location = { directory = "/proj" },
  data = {
    { id = "alpha", name = "alpha", description = "A", path = "/x/alpha/SKILL.md" },
    { id = "opencode", name = "OpenCode", path = "/builtin/opencode.md" },
    { id = "alpha", name = "alpha", description = "dup", path = "/y/alpha/SKILL.md" },
  },
}

-- A representative `opencode api command.list` payload. `gamma` carries no description.
local COMMANDS = {
  location = { directory = "/proj" },
  data = {
    { name = "zeta", description = "Z" },
    { name = "gamma" },
  },
}

T["parse_skills"] = new_set()

T["parse_skills"]["maps id, description, and path"] = function()
  local oc = require("agentcomplete.opencode_cli")
  local skills = oc.parse_skills(SKILLS)
  expect.equality(#skills, 3) -- duplicate retained; dedup is downstream
  expect.equality(skills[1].name, "alpha")
  expect.equality(skills[1].description, "A")
  expect.equality(skills[1].path, "/x/alpha/SKILL.md")
end

-- The TUI inserts a skill by id; `name` is a display title.
T["parse_skills"]["names a skill by the id the TUI inserts, not its display title"] = function()
  local oc = require("agentcomplete.opencode_cli")
  local skills = oc.parse_skills(SKILLS)
  expect.equality(skills[2].name, "opencode")
  expect.equality(skills[2].description, nil)
end

T["parse_skills"]["a payload without a data array yields an empty list"] = function()
  local oc = require("agentcomplete.opencode_cli")
  expect.equality(oc.parse_skills({ error = "boom" }), {})
  expect.equality(oc.parse_skills("text"), {})
end

T["parse_skills"]["entries without a string id are skipped"] = function()
  local oc = require("agentcomplete.opencode_cli")
  expect.equality(oc.parse_skills({ data = { { name = "no id" } } }), {})
end

T["parse_commands"] = new_set()

T["parse_commands"]["reads the command list with descriptions"] = function()
  local oc = require("agentcomplete.opencode_cli")
  local cmds = oc.parse_commands(COMMANDS)
  expect.equality(#cmds, 2)
  expect.equality(cmds[1].name, "zeta")
  expect.equality(cmds[1].description, "Z")
  expect.equality(cmds[2].name, "gamma")
  expect.equality(cmds[2].description, nil)
end

-- The whole point of this probe: OpenCode resolves plugin-contributed commands from its package
-- cache, which no config-dir scan reaches, so they arrive only from OpenCode itself.
T["parse_commands"]["surfaces a plugin-contributed, namespaced command"] = function()
  local oc = require("agentcomplete.opencode_cli")
  local cmds =
    oc.parse_commands({ data = { { name = "caret:debug", description = "D" } } })
  expect.equality(cmds[1].name, "caret:debug")
  expect.equality(cmds[1].description, "D")
end

T["parse_commands"]["a payload without a data array yields an empty list"] = function()
  local oc = require("agentcomplete.opencode_cli")
  expect.equality(oc.parse_commands({ model = "x" }), {})
end

T["get"] = new_set()

T["get"]["spawns once per cwd and returns the empty cache while pending"] = function()
  local oc = require("agentcomplete.opencode_cli")
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
  local oc = require("agentcomplete.opencode_cli")
  local spawned = false
  local spawn = function()
    spawned = true
  end
  oc._cache["/proj"] =
    { started = true, skills = { { name = "x" } }, commands = { { name = "c" } } }
  local got = oc.get("/proj", spawn)
  expect.equality(got.skills[1].name, "x")
  expect.equality(got.commands[1].name, "c")
  expect.equality(spawned, false)
end

T["fill"] = new_set()

---An entry as `get` would hand out, plus the probe row for `field`.
local function entry_and_probe(oc, field)
  local probe
  for _, p in ipairs(oc.probes) do
    if p.field == field then
      probe = p
    end
  end
  return { started = true, skills = {}, commands = {} },
    assert(probe, "no probe for field " .. field)
end

T["fill"]["populates the probe's list in place"] = function()
  local oc = require("agentcomplete.opencode_cli")
  local entry, probe = entry_and_probe(oc, "skills")
  local captured = entry.skills -- a caller (e.g. the native backend's cached session) holding the ref
  oc._fill(entry, probe, SKILLS)
  expect.equality(#entry.skills, 3)
  expect.equality(captured == entry.skills, true) -- mutated in place, not replaced, so the ref stays live
end

-- Each probe fills only its own field, so a command payload must not disturb the skills list
-- (and vice versa) — the two jobs land independently and in no guaranteed order.
T["fill"]["the commands probe fills commands and leaves skills alone"] = function()
  local oc = require("agentcomplete.opencode_cli")
  local entry, probe = entry_and_probe(oc, "commands")
  local captured = entry.commands
  oc._fill(entry, probe, COMMANDS)
  expect.equality(#entry.commands, 2)
  expect.equality(entry.skills, {})
  expect.equality(captured == entry.commands, true)
end

T["fill"]["leaves the list alone when the request failed"] = function()
  local oc = require("agentcomplete.opencode_cli")
  local entry, probe = entry_and_probe(oc, "skills")
  oc._fill(entry, probe, nil)
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
  local highlight = require("agentcomplete.highlight")
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
T["fill"]["repaints attached buffers so late-resolved skills paint"] = function()
  local oc = require("agentcomplete.opencode_cli")
  local entry, probe = entry_and_probe(oc, "skills")
  local buf = attached_buf(entry, { "/alpha" })
  expect.equality(painted(buf), {}) -- pending: nothing resolves yet

  oc._fill(entry, probe, SKILLS)
  expect.equality(
    painted(buf),
    { { row = 0, col = 0, end_col = 6, hl_group = "AgentCompleteSkill" } }
  )
end

T["fill"]["repaints attached buffers so late-resolved commands paint"] = function()
  local oc = require("agentcomplete.opencode_cli")
  local entry, probe = entry_and_probe(oc, "commands")
  local buf = attached_buf(entry, { "/zeta" })
  expect.equality(painted(buf), {})

  oc._fill(entry, probe, COMMANDS)
  expect.equality(
    painted(buf),
    { { row = 0, col = 0, end_col = 5, hl_group = "AgentCompleteSkill" } }
  )
end

T["fill"]["a failed request neither resolves nor paints"] = function()
  local oc = require("agentcomplete.opencode_cli")
  local entry, probe = entry_and_probe(oc, "skills")
  local buf = attached_buf(entry, { "/alpha" })
  oc._fill(entry, probe, nil)
  expect.equality(painted(buf), {})
end

T["api"] = new_set()

---A temp file holding `payload`, as the command's redirected stdout.
local function stdout_file(payload)
  local path = vim.fn.tempname()
  vim.fn.writefile(vim.split(payload, "\n"), path)
  return path
end

---Call `_on_exit` and return what it handed its callback.
local function on_exit(obj, path)
  local got = {}
  require("agentcomplete.opencode_cli")._on_exit(obj, path, function(data, err)
    got = { data = data, err = err }
  end)
  return got
end

T["api"]["decodes the redirected output and removes the temp file"] = function()
  local path = stdout_file('{"data":[{"name":"x"}]}')
  local got = on_exit({ code = 0 }, path)
  expect.equality(got.data, { data = { { name = "x" } } })
  expect.equality(vim.loop.fs_stat(path), nil)
end

T["api"]["reports a non-zero exit with its stderr"] = function()
  local got = on_exit({ code = 1, stderr = "no server\n" }, stdout_file("{}"))
  expect.equality(got.data, nil)
  expect.equality(got.err, "opencode api exited 1: no server")
end

T["api"]["reports output that is not JSON"] = function()
  local got = on_exit({ code = 0 }, stdout_file("HTTP 404 Not Found"))
  expect.equality(got.data, nil)
  expect.equality(type(got.err), "string")
end

-- Bun truncates large output through a pipe (~64KB), which `skill.list` exceeds outright.
T["api"]["redirects stdout to a temp file rather than reading a pipe"] = function()
  local oc = require("agentcomplete.opencode_cli")
  local cmd
  oc.api(
    { "skill.list", "--param", "location[directory]=/it's" },
    function() end,
    function(c)
      cmd = c
    end
  )
  expect.equality(cmd[1], "sh")
  expect.equality(
    cmd[3]:match(
      "^opencode api 'skill.list' '%-%-param' 'location%[directory%]=/it'\\''s' > "
    ) ~= nil,
    true
  )
end

T["api"]["reports a spawn that throws instead of raising"] = function()
  local oc = require("agentcomplete.opencode_cli")
  local err
  oc.api({ "skill.list" }, function(_, e)
    err = e
  end, function()
    error("ENOENT")
  end)
  expect.equality(type(err), "string")
end

T["spawn"] = new_set()

T["spawn"]["asks for each probe's set at the session's location"] = function()
  local oc = require("agentcomplete.opencode_cli")
  local cmds = {}
  local system = function(cmd)
    cmds[#cmds + 1] = cmd[3]
  end
  oc._spawn("/proj", { started = true, skills = {}, commands = {} }, system)
  expect.equality(#cmds, #oc.probes)
  expect.equality(
    cmds[1]:match(
      "^opencode api 'skill.list' '%-%-param' 'location%[directory%]=/proj' > "
    ) ~= nil,
    true
  )
  expect.equality(cmds[2]:match("^opencode api 'command.list' ") ~= nil, true)
end

return T
