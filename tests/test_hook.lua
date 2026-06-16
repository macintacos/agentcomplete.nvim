-- Tests for the companion Claude Code plugin hook script: it writes a
-- per-session state file containing the cwd and removes it on SessionEnd.
local MiniTest = require "mini.test"
local new_set = MiniTest.new_set
local expect = MiniTest.expect

local script = vim.loop.cwd() .. "/hooks/agentcomplete-state.sh"

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

---Run the hook with a fixture payload under an isolated XDG_CACHE_HOME.
local function run_hook(cache, payload)
  local out = vim.fn.system({ "env", "XDG_CACHE_HOME=" .. cache, "bash", script }, vim.json.encode(payload))
  return out
end

local T = new_set()

T["SessionStart writes a state file containing the cwd"] = function()
  local cache = tmpdir()
  run_hook(cache, { hook_event_name = "SessionStart", session_id = "hooktest", cwd = "/tmp/projX" })
  expect.equality(vim.v.shell_error, 0)
  local state = cache .. "/agentcomplete/hooktest.json"
  expect.equality(vim.fn.filereadable(state), 1)
  local data = vim.json.decode(table.concat(vim.fn.readfile(state), "\n"))
  expect.equality(data.cwd, "/tmp/projX")
end

T["PostToolUse updates the cwd as the agent navigates"] = function()
  local cache = tmpdir()
  run_hook(cache, { hook_event_name = "SessionStart", session_id = "nav", cwd = "/tmp/a" })
  run_hook(cache, { hook_event_name = "PostToolUse", session_id = "nav", cwd = "/tmp/b" })
  local data = vim.json.decode(table.concat(vim.fn.readfile(cache .. "/agentcomplete/nav.json"), "\n"))
  expect.equality(data.cwd, "/tmp/b")
end

T["SessionEnd removes the state file"] = function()
  local cache = tmpdir()
  run_hook(cache, { hook_event_name = "SessionStart", session_id = "gone", cwd = "/tmp/x" })
  expect.equality(vim.fn.filereadable(cache .. "/agentcomplete/gone.json"), 1)
  run_hook(cache, { hook_event_name = "SessionEnd", session_id = "gone", cwd = "/tmp/x" })
  expect.equality(vim.fn.filereadable(cache .. "/agentcomplete/gone.json"), 0)
end

T["missing session id is a quiet no-op"] = function()
  local cache = tmpdir()
  run_hook(cache, { hook_event_name = "SessionStart", cwd = "/tmp/x" })
  expect.equality(vim.v.shell_error, 0)
  expect.equality(vim.fn.isdirectory(cache .. "/agentcomplete"), 0)
end

return T
