-- Tests for agentcomplete.opencode_skills: pure JSON parsing of `opencode debug
-- skill` output plus the lazy per-cwd async cache (with the subprocess injected).
local MiniTest = require "mini.test"
local new_set = MiniTest.new_set
local expect = MiniTest.expect

-- Reload the module fresh for each case so its cache resets.
local T = new_set {
  hooks = {
    pre_case = function()
      package.loaded["agentcomplete.opencode_skills"] = nil
    end,
  },
}

-- A representative `opencode debug skill` payload: a built-in (no path, no
-- description) and a duplicated name (dedup happens downstream in `sources`).
local SAMPLE = table.concat({
  "[",
  '  {"name":"alpha","description":"A","location":"/x/alpha/SKILL.md","content":"# Alpha"},',
  '  {"name":"beta","location":"<built-in>"},',
  '  {"name":"alpha","description":"dup","location":"/y/alpha/SKILL.md"}',
  "]",
}, "\n")

T["parse"] = new_set()

T["parse"]["maps name, description, and location -> path"] = function()
  local oc = require "agentcomplete.opencode_skills"
  local skills = assert(oc.parse(SAMPLE))
  expect.equality(#skills, 3) -- duplicate retained; dedup is downstream
  expect.equality(skills[1].name, "alpha")
  expect.equality(skills[1].description, "A")
  expect.equality(skills[1].path, "/x/alpha/SKILL.md")
end

T["parse"]["a missing description becomes nil; a built-in keeps its location"] = function()
  local oc = require "agentcomplete.opencode_skills"
  local skills = assert(oc.parse(SAMPLE))
  expect.equality(skills[2].name, "beta")
  expect.equality(skills[2].description, nil)
  expect.equality(skills[2].path, "<built-in>")
end

T["parse"]["invalid JSON returns nil"] = function()
  local oc = require "agentcomplete.opencode_skills"
  expect.equality(oc.parse "not json{", nil)
end

T["parse"]["a JSON object (non-array) yields an empty list"] = function()
  local oc = require "agentcomplete.opencode_skills"
  expect.equality(oc.parse '{"foo":1}', {})
end

T["parse"]["entries without a string name are skipped"] = function()
  local oc = require "agentcomplete.opencode_skills"
  expect.equality(oc.parse '[{"description":"no name"}]', {})
end

T["get"] = new_set()

T["get"]["spawns once per cwd and returns the empty cache while pending"] = function()
  local oc = require "agentcomplete.opencode_skills"
  local calls = 0
  local spawn = function()
    calls = calls + 1
  end
  local a = oc.get("/proj", spawn)
  local b = oc.get("/proj", spawn)
  expect.equality(calls, 1) -- guarded: at most one spawn per cwd
  expect.equality(a, {}) -- empty while the job is pending
  expect.equality(b, {})
end

T["get"]["returns a pre-seeded cache verbatim without spawning"] = function()
  local oc = require "agentcomplete.opencode_skills"
  local spawned = false
  local spawn = function()
    spawned = true
  end
  oc._cache["/proj"] = { started = true, skills = { { name = "x" } } }
  local got = oc.get("/proj", spawn)
  expect.equality(got[1].name, "x")
  expect.equality(spawned, false)
end

T["on_exit"] = new_set()

T["on_exit"]["populates skills from the output file on a clean exit"] = function()
  local oc = require "agentcomplete.opencode_skills"
  local path = vim.fn.tempname()
  vim.fn.writefile(vim.split(SAMPLE, "\n"), path)
  local entry = { started = true, skills = {} }
  oc._on_exit(entry, { code = 0 }, path)
  expect.equality(#entry.skills, 3)
end

T["on_exit"]["leaves skills empty on a non-zero exit"] = function()
  local oc = require "agentcomplete.opencode_skills"
  local entry = { started = true, skills = {} }
  oc._on_exit(entry, { code = 1 }, vim.fn.tempname())
  expect.equality(entry.skills, {})
end

T["spawn"] = new_set()

T["spawn"]["a throwing system call is guarded: no error, skills stay empty"] = function()
  local oc = require "agentcomplete.opencode_skills"
  local throwing = function()
    error "ENOENT"
  end
  local entry = { started = true, skills = {} }
  oc._spawn("/proj", entry, throwing) -- must not raise
  expect.equality(entry.skills, {})
end

return T
