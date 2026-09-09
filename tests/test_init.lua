-- Tests for agentcomplete top-level: config merge, public commands.
local MiniTest = require "mini.test"
local new_set = MiniTest.new_set
local expect = MiniTest.expect

local T = new_set()

T["setup merges user config over defaults and returns the module"] = function()
  local agentcomplete = require "agentcomplete"
  local m = agentcomplete.setup { backend = "native" }
  expect.equality(m, agentcomplete)
  expect.equality(agentcomplete.config.backend, "native")
  expect.equality(agentcomplete.config.enabled, true) -- default preserved
  expect.equality(agentcomplete.config.sources.slash, true) -- nested default preserved
end

T["setup registers the manual attach/detach commands"] = function()
  require("agentcomplete").setup()
  expect.equality(vim.fn.exists ":AgentCompleteAttach", 2)
  expect.equality(vim.fn.exists ":AgentCompleteDetach", 2)
end

T["setup registers the Claude Code detector"] = function()
  require("agentcomplete").setup()
  local detect = require "agentcomplete.detect"
  local names = vim.tbl_map(function(d)
    return d.name
  end, detect.detectors)
  expect.equality(vim.tbl_contains(names, "claude-code"), true)
end

T["setup registers the Claude Code context resolver"] = function()
  require("agentcomplete").setup()
  local names = vim.tbl_map(function(r)
    return r.name
  end, require("agentcomplete.context").resolvers)
  expect.equality(vim.tbl_contains(names, "claude-code"), true)
end

T["setup defaults the context pane on, with a split-direction threshold"] = function()
  local agentcomplete = require "agentcomplete"
  agentcomplete.setup {}
  expect.equality(agentcomplete.config.context.enabled, true)
  expect.equality(agentcomplete.config.context.min_width, 160)
end

T["setup merges a context override over the defaults"] = function()
  local agentcomplete = require "agentcomplete"
  agentcomplete.setup { context = { enabled = false } }
  expect.equality(agentcomplete.config.context.enabled, false)
  expect.equality(agentcomplete.config.context.min_width, 160) -- sibling default preserved
end

T["setup preserves the opencode.show_all_builtin_commands default"] = function()
  local agentcomplete = require "agentcomplete"
  agentcomplete.setup {}
  expect.equality(agentcomplete.config.opencode.show_all_builtin_commands, false)
end

T["setup merges the opencode option over the default"] = function()
  local agentcomplete = require "agentcomplete"
  agentcomplete.setup { opencode = { show_all_builtin_commands = true } }
  expect.equality(agentcomplete.config.opencode.show_all_builtin_commands, true)
  expect.equality(agentcomplete.config.enabled, true) -- unrelated default preserved
end

return T
