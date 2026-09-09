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
  expect.equality(vim.fn.exists ":AgentCompleteInstallOpenCodePlugin", 2)
end

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

T["install_opencode_plugin"] = new_set()

T["install_opencode_plugin"]["symlinks the plugin into the config home"] = function()
  local source, home = tmpdir() .. "/agentcomplete.ts", tmpdir()
  vim.fn.writefile({ "" }, source)
  local status, target = require("agentcomplete").install_opencode_plugin(source, home)
  expect.equality(status, "created")
  expect.equality(target, home .. "/plugin/agentcomplete.ts")
  expect.equality(vim.loop.fs_readlink(target), source)
end

T["install_opencode_plugin"]["reports an existing link to the same source as already current"] = function()
  local source, home = tmpdir() .. "/agentcomplete.ts", tmpdir()
  vim.fn.writefile({ "" }, source)
  local install = require("agentcomplete").install_opencode_plugin
  install(source, home)
  expect.equality(install(source, home), "current")
end

-- Refusing rather than overwriting: whatever is there is the user's, and a symlink from an
-- older checkout reads the same as a hand-written plugin.
T["install_opencode_plugin"]["refuses when something else already occupies the target"] = function()
  local source, home = tmpdir() .. "/agentcomplete.ts", tmpdir()
  vim.fn.writefile({ "" }, source)
  vim.fn.mkdir(home .. "/plugin", "p")
  vim.fn.writefile({ "mine" }, home .. "/plugin/agentcomplete.ts")
  expect.equality(require("agentcomplete").install_opencode_plugin(source, home), "conflict")
  expect.equality(vim.fn.readfile(home .. "/plugin/agentcomplete.ts"), { "mine" })
end

T["setup registers the Claude Code detector"] = function()
  require("agentcomplete").setup()
  local detect = require "agentcomplete.detect"
  local names = vim.tbl_map(function(d)
    return d.name
  end, detect.detectors)
  expect.equality(vim.tbl_contains(names, "claude-code"), true)
end

T["setup registers the built-in context resolvers"] = function()
  require("agentcomplete").setup()
  local names = vim.tbl_map(function(r)
    return r.name
  end, require("agentcomplete.context").resolvers)
  expect.equality(vim.tbl_contains(names, "claude-code"), true)
  expect.equality(vim.tbl_contains(names, "opencode"), true)
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
