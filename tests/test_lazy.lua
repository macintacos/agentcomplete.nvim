-- Tests for lazy loading: which agentcomplete modules setup() and blink's provider load.
-- Runs in a child Neovim because the in-process suite has already loaded every module.
-- blink.cmp is off the test runtimepath, so the blink case fakes it with package.preload.

local MiniTest = require("mini.test")
local new_set, expect = MiniTest.new_set, MiniTest.expect

local child = MiniTest.new_child_neovim()

local STARTUP = {
  "agentcomplete",
  "agentcomplete.detect",
  "agentcomplete.detect.claude_code",
  "agentcomplete.detect.opencode",
}

---The `agentcomplete*` modules the child has loaded, sorted.
---@return string[]
local function loaded()
  return child.lua([[
    local names = {}
    for name in pairs(package.loaded) do
      if name:match("^agentcomplete") then
        table.insert(names, name)
      end
    end
    table.sort(names)
    return names
  ]])
end

---A Claude Code prompt file that exists, so `:edit` fires BufReadPost.
---@return string
local function prompt_file()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/claude-prompt-lazy.md"
  vim.fn.writefile({}, path)
  return path
end

---Point the child's `~/.claude` and project root at an empty dir, so attaching scans
---nothing real.
local function isolate()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  child.lua("vim.env.CLAUDE_CONFIG_DIR = ...; vim.g.agentcomplete_cwd = ...", { root })
end

---Fake blink.cmp in the child with `providers` as its registered sources.
---@param providers table
local function fake_blink(providers)
  child.lua(
    [[
    local providers = ...
    package.preload["blink.cmp"] = function()
      return {}
    end
    package.preload["blink.cmp.config"] = function()
      return { sources = { default = { "lsp" }, providers = providers } }
    end
  ]],
    { providers }
  )
end

local T = new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "tests/minimal_init.lua" })
    end,
    post_once = child.stop,
  },
})

T["setup loads only what detection needs"] = function()
  child.lua([[require("agentcomplete").setup({})]])
  expect.equality(loaded(), STARTUP)
end

T["reading a file that is not a prompt loads nothing more"] = function()
  child.lua([[require("agentcomplete").setup({})]])
  child.cmd("edit README.md")
  expect.equality(loaded(), STARTUP)
end

T["blink is left alone until a prompt buffer attaches"] = function()
  isolate()
  fake_blink({ agentcomplete = {} })
  child.lua([[require("agentcomplete").setup({})]])
  expect.equality(child.lua_get([[package.loaded["blink.cmp"] == nil]]), true)
  child.cmd("edit " .. prompt_file())
  expect.equality(
    child.lua_get([[type(require("blink.cmp.config").sources.default)]]),
    "function"
  )
end

T["attaching a prompt buffer twice warns once"] = function()
  isolate()
  fake_blink({ agentcomplete = {} })
  child.lua([[
    _G.warns = 0
    vim.notify = function(_, level)
      if level == vim.log.levels.WARN then
        _G.warns = _G.warns + 1
      end
    end
    require("agentcomplete").setup({ allowed_sources = { "nope" } })
  ]])
  child.cmd("edit " .. prompt_file())
  child.cmd("AgentCompleteAttach")
  expect.equality(child.lua_get("_G.warns"), 1)
end

T["blink's provider module does not load the sources"] = function()
  child.lua([[require("agentcomplete.backends.blink")]])
  expect.equality(child.lua_get([[package.loaded["agentcomplete.sources"] == nil]]), true)
end

return T
