-- Tests for agentcomplete.detect: the per-tool detector registry and the
-- Claude Code detector (env session-id + companion-plugin state file).
local MiniTest = require "mini.test"
local new_set = MiniTest.new_set
local expect = MiniTest.expect

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

local saved = {}
local T = new_set {
  hooks = {
    pre_case = function()
      saved.sid = vim.env.CLAUDE_CODE_SESSION_ID
      saved.xdg = vim.env.XDG_CACHE_HOME
    end,
    post_case = function()
      vim.env.CLAUDE_CODE_SESSION_ID = saved.sid
      vim.env.XDG_CACHE_HOME = saved.xdg
    end,
  },
}

T["registry"] = new_set()

T["registry"]["detect returns nil when no detectors are registered"] = function()
  local detect = require "agentcomplete.detect"
  detect.clear()
  expect.equality(detect.detect(0), nil)
end

T["registry"]["detect returns the first matching detector's session"] = function()
  local detect = require "agentcomplete.detect"
  detect.clear()
  detect.register {
    name = "a",
    detect = function()
      return nil
    end,
  }
  detect.register {
    name = "b",
    detect = function()
      return { tool = "b" }
    end,
  }
  detect.register {
    name = "c",
    detect = function()
      return { tool = "c" }
    end,
  }
  expect.equality(assert(detect.detect(0)).tool, "b")
end

T["registry"]["a throwing detector is skipped, not fatal"] = function()
  local detect = require "agentcomplete.detect"
  detect.clear()
  detect.register {
    name = "boom",
    detect = function()
      error "kaboom"
    end,
  }
  detect.register {
    name = "ok",
    detect = function()
      return { tool = "ok" }
    end,
  }
  expect.equality(assert(detect.detect(0)).tool, "ok")
end

T["claude_code"] = new_set()

T["claude_code"]["returns nil when the session-id env var is unset"] = function()
  vim.env.XDG_CACHE_HOME = tmpdir()
  vim.env.CLAUDE_CODE_SESSION_ID = nil
  local cc = require "agentcomplete.detect.claude_code"
  expect.equality(cc.detect(0), nil)
end

T["claude_code"]["returns nil when no state file exists for the session"] = function()
  vim.env.XDG_CACHE_HOME = tmpdir()
  vim.env.CLAUDE_CODE_SESSION_ID = "sess-1"
  local cc = require "agentcomplete.detect.claude_code"
  expect.equality(cc.detect(0), nil)
end

T["claude_code"]["returns a session using the state-file cwd and derived dirs"] = function()
  local cache = tmpdir()
  vim.env.XDG_CACHE_HOME = cache
  vim.env.CLAUDE_CODE_SESSION_ID = "sess-2"
  vim.fn.mkdir(cache .. "/agentcomplete", "p")
  vim.fn.writefile({ vim.json.encode { cwd = "/tmp/projX" } }, cache .. "/agentcomplete/sess-2.json")

  local cc = require "agentcomplete.detect.claude_code"
  local s = assert(cc.detect(0))
  expect.equality(s.tool, "claude-code")
  expect.equality(s.session_id, "sess-2")
  expect.equality(s.cwd, "/tmp/projX")
  expect.equality(vim.tbl_contains(s.skill_dirs, "/tmp/projX/.claude/skills"), true)
  expect.equality(vim.tbl_contains(s.command_dirs, "/tmp/projX/.claude/commands"), true)
  expect.equality(vim.tbl_contains(s.skill_dirs, vim.fn.expand "~/.claude" .. "/skills"), true)
end

T["claude_code"]["falls back to vim.loop.cwd() when the state file lacks a cwd"] = function()
  local cache = tmpdir()
  vim.env.XDG_CACHE_HOME = cache
  vim.env.CLAUDE_CODE_SESSION_ID = "sess-3"
  vim.fn.mkdir(cache .. "/agentcomplete", "p")
  vim.fn.writefile({ "{}" }, cache .. "/agentcomplete/sess-3.json")

  local cc = require "agentcomplete.detect.claude_code"
  expect.equality(assert(cc.detect(0)).cwd, vim.loop.cwd())
end

return T
