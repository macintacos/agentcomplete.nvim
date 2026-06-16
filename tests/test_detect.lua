-- Tests for agentcomplete.detect: the per-tool detector registry and the
-- Claude Code detector (prompt-buffer name + editor cwd).
local MiniTest = require "mini.test"
local new_set = MiniTest.new_set
local expect = MiniTest.expect

-- Create a scratch buffer with the given absolute name; returns its bufnr.
-- Names must be unique across cases (Neovim forbids two buffers sharing a name).
local function named_buf(name)
  local buf = vim.api.nvim_create_buf(false, true)
  if name ~= "" then
    vim.api.nvim_buf_set_name(buf, name)
  end
  return buf
end

local saved = {}
local T = new_set {
  hooks = {
    pre_case = function()
      saved.env = vim.env.AGENTCOMPLETE_CWD
      saved.g = vim.g.agentcomplete_cwd
    end,
    post_case = function()
      vim.env.AGENTCOMPLETE_CWD = saved.env
      vim.g.agentcomplete_cwd = saved.g
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

T["claude_code"]["matches a claude-prompt-<uuid>.md buffer, rooted at cwd"] = function()
  vim.env.AGENTCOMPLETE_CWD = nil
  vim.g.agentcomplete_cwd = nil
  local buf = named_buf "/private/tmp/claude-502/claude-prompt-abc12345.md"
  local cc = require "agentcomplete.detect.claude_code"
  local s = assert(cc.detect(buf))
  expect.equality(s.tool, "claude-code")
  expect.equality(s.session_id, nil)
  expect.equality(s.cwd, vim.loop.cwd())
  expect.equality(#s.skill_dirs > 0, true)
  expect.equality(#s.command_dirs > 0, true)
end

T["claude_code"]["ignores buffers that are not a claude prompt"] = function()
  local cc = require "agentcomplete.detect.claude_code"
  expect.equality(cc.detect(named_buf "/tmp/ac-a/notes.md"), nil)
  expect.equality(cc.detect(named_buf "/tmp/ac-b/claude-prompt.txt"), nil) -- wrong extension
  expect.equality(cc.detect(named_buf "/tmp/ac-c/prompt-x.md"), nil) -- wrong prefix
  expect.equality(cc.detect(named_buf ""), nil) -- unnamed buffer
end

T["claude_code"]["AGENTCOMPLETE_CWD env wins over vim.g and cwd"] = function()
  vim.env.AGENTCOMPLETE_CWD = "/tmp/projEnv"
  vim.g.agentcomplete_cwd = "/tmp/projG"
  local cc = require "agentcomplete.detect.claude_code"
  local s = assert(cc.detect(named_buf "/tmp/ac-d/claude-prompt-d.md"))
  expect.equality(s.cwd, "/tmp/projEnv")
end

T["claude_code"]["vim.g.agentcomplete_cwd wins over cwd when env is unset"] = function()
  vim.env.AGENTCOMPLETE_CWD = nil
  vim.g.agentcomplete_cwd = "/tmp/projG"
  local cc = require "agentcomplete.detect.claude_code"
  local s = assert(cc.detect(named_buf "/tmp/ac-e/claude-prompt-e.md"))
  expect.equality(s.cwd, "/tmp/projG")
end

T["claude_code"]["empty AGENTCOMPLETE_CWD is ignored (treated as unset)"] = function()
  vim.env.AGENTCOMPLETE_CWD = ""
  vim.g.agentcomplete_cwd = "/tmp/projG"
  local cc = require "agentcomplete.detect.claude_code"
  local s = assert(cc.detect(named_buf "/tmp/ac-f/claude-prompt-f.md"))
  expect.equality(s.cwd, "/tmp/projG")
end

T["claude_code"]["derives project-local skill/command dirs from the resolved cwd"] = function()
  vim.env.AGENTCOMPLETE_CWD = "/tmp/projX"
  vim.g.agentcomplete_cwd = nil
  local cc = require "agentcomplete.detect.claude_code"
  local s = assert(cc.detect(named_buf "/tmp/ac-g/claude-prompt-g.md"))
  expect.equality(vim.tbl_contains(s.skill_dirs, "/tmp/projX/.claude/skills"), true)
  expect.equality(vim.tbl_contains(s.command_dirs, "/tmp/projX/.claude/commands"), true)
end

return T
