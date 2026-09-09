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

-- A link we wrote for a checkout that has since moved is indistinguishable from a stale one
-- the user wrote; re-pointing it is what keeps a moved checkout from erroring on every launch.
T["install_opencode_plugin"]["re-points a link left by another checkout"] = function()
  local stale, source, home = tmpdir() .. "/opencode/agentcomplete.ts", tmpdir() .. "/agentcomplete.ts", tmpdir()
  vim.fn.writefile({ "" }, source)
  vim.fn.mkdir(home .. "/plugin", "p")
  vim.loop.fs_symlink(stale, home .. "/plugin/agentcomplete.ts")
  local status, target = require("agentcomplete").install_opencode_plugin(source, home)
  expect.equality(status, "relinked")
  expect.equality(vim.loop.fs_readlink(target), source)
end

T["install_opencode_plugin"]["refuses a symlink that is not one of ours"] = function()
  local source, home = tmpdir() .. "/agentcomplete.ts", tmpdir()
  vim.fn.writefile({ "" }, source)
  vim.fn.mkdir(home .. "/plugin", "p")
  vim.loop.fs_symlink(tmpdir() .. "/notes.md", home .. "/plugin/agentcomplete.ts")
  expect.equality(require("agentcomplete").install_opencode_plugin(source, home), "conflict")
end

---Put a stub `opencode` on PATH, so what `setup()` does is decided by the test rather than by
---whether the machine running it happens to have OpenCode installed.
local function stub_opencode_on_path()
  local bin = tmpdir()
  vim.fn.writefile({ "#!/bin/sh" }, bin .. "/opencode")
  vim.fn.setfperm(bin .. "/opencode", "rwxr-xr-x")
  vim.env.PATH = bin .. ":" .. vim.env.PATH
end

local saved_xdg, saved_path, saved_notify, notes
T["install_plugin"] = new_set {
  hooks = {
    pre_case = function()
      saved_xdg, saved_path = vim.env.XDG_CONFIG_HOME, vim.env.PATH
      vim.env.XDG_CONFIG_HOME = tmpdir()
      stub_opencode_on_path()
      notes, saved_notify = {}, vim.notify
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
      end
    end,
    post_case = function()
      vim.env.XDG_CONFIG_HOME = saved_xdg
      vim.env.PATH = saved_path
      vim.notify = saved_notify
    end,
  },
}

T["install_plugin"]["defaults off, and installs nothing"] = function()
  local agentcomplete = require "agentcomplete"
  agentcomplete.setup {}
  expect.equality(agentcomplete.config.opencode.install_plugin, false)
  expect.equality(vim.loop.fs_lstat(vim.env.XDG_CONFIG_HOME .. "/opencode/plugin/agentcomplete.ts"), nil)
end

T["install_plugin"]["symlinks the shipped plugin when opted in"] = function()
  require("agentcomplete").setup { opencode = { install_plugin = true } }
  local target = vim.env.XDG_CONFIG_HOME .. "/opencode/plugin/agentcomplete.ts"
  local linked = vim.loop.fs_readlink(target)
  expect.equality(type(linked), "string")
  ---@cast linked string
  expect.equality(vim.endswith(linked, "opencode/agentcomplete.ts"), true)
  -- fs_stat follows the link, so this is what separates an installed plugin from a dangling one.
  expect.equality(vim.loop.fs_stat(target) ~= nil, true)
end

T["install_plugin"]["reports a conflict rather than overwriting what is already there"] = function()
  local plugin_dir = vim.env.XDG_CONFIG_HOME .. "/opencode/plugin"
  vim.fn.mkdir(plugin_dir, "p")
  vim.fn.writefile({ "mine" }, plugin_dir .. "/agentcomplete.ts")
  require("agentcomplete").setup { opencode = { install_plugin = true } }
  expect.equality(#notes, 1)
  expect.equality(notes[1].level, vim.log.levels.ERROR)
  expect.equality(vim.fn.readfile(plugin_dir .. "/agentcomplete.ts"), { "mine" })
end

-- The flag ships in a synced config, so it runs on machines the user is not thinking about;
-- installing there would plant an OpenCode config directory on a machine that has never had one.
T["install_plugin"]["installs nothing on a machine without OpenCode"] = function()
  vim.env.PATH = tmpdir()
  require("agentcomplete").setup { opencode = { install_plugin = true } }
  expect.equality(vim.loop.fs_lstat(vim.env.XDG_CONFIG_HOME .. "/opencode"), nil)
  expect.equality(#notes, 0)
end

T["install_plugin"]["reports the install once, then stays quiet on later setups"] = function()
  require("agentcomplete").setup { opencode = { install_plugin = true } }
  require("agentcomplete").setup { opencode = { install_plugin = true } }
  expect.equality(#notes, 1)
  expect.equality(notes[1].level, vim.log.levels.INFO)
end

-- The command is an explicit request, so unlike the flag it installs wherever it is typed —
-- including a machine whose OpenCode is not on Neovim's PATH.
T["install_plugin"]["the command installs and reports even without OpenCode on PATH"] = function()
  vim.env.PATH = tmpdir()
  require("agentcomplete").setup {}
  vim.cmd "AgentCompleteInstallOpenCodePlugin"
  expect.equality(vim.loop.fs_stat(vim.env.XDG_CONFIG_HOME .. "/opencode/plugin/agentcomplete.ts") ~= nil, true)
  expect.equality(#notes, 1)
  expect.equality(notes[1].level, vim.log.levels.INFO)
end

T["install_plugin"]["the command reports when the shipped plugin is off the runtimepath"] = function()
  local saved_rtp = vim.o.runtimepath
  vim.o.runtimepath = tmpdir()
  require("agentcomplete").setup {}
  vim.cmd "AgentCompleteInstallOpenCodePlugin"
  vim.o.runtimepath = saved_rtp
  expect.equality(vim.loop.fs_lstat(vim.env.XDG_CONFIG_HOME .. "/opencode"), nil)
  expect.equality(#notes, 1)
  expect.equality(notes[1].level, vim.log.levels.ERROR)
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
