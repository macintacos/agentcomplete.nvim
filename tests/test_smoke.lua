-- Smoke test: proves the toolchain (mini.test under headless Neovim) works and
-- the plugin module loads. Replace with real tests as features land.
local MiniTest = require "mini.test"
local new_set = MiniTest.new_set
local expect = MiniTest.expect

local T = new_set()

T["module loads"] = function()
  local ok, agentcomplete = pcall(require, "agentcomplete")
  expect.equality(ok, true)
  expect.equality(type(agentcomplete.setup), "function")
end

T["setup returns the module"] = function()
  local agentcomplete = require "agentcomplete"
  expect.equality(agentcomplete.setup(), agentcomplete)
end

return T
