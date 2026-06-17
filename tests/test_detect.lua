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

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

local function write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

local saved = {}
local T = new_set {
  hooks = {
    pre_case = function()
      saved.env = vim.env.AGENTCOMPLETE_CWD
      saved.g = vim.g.agentcomplete_cwd
      saved.opencode = vim.env.OPENCODE
      saved.opencode_pid = vim.env.OPENCODE_PID
      saved.xdg = vim.env.XDG_CONFIG_HOME
      saved.oc_config = vim.env.OPENCODE_CONFIG
      saved.oc_config_dir = vim.env.OPENCODE_CONFIG_DIR
    end,
    post_case = function()
      vim.env.AGENTCOMPLETE_CWD = saved.env
      vim.g.agentcomplete_cwd = saved.g
      vim.env.OPENCODE = saved.opencode
      vim.env.OPENCODE_PID = saved.opencode_pid
      vim.env.XDG_CONFIG_HOME = saved.xdg
      vim.env.OPENCODE_CONFIG = saved.oc_config
      vim.env.OPENCODE_CONFIG_DIR = saved.oc_config_dir
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

T["claude_code"]["empty vim.g.agentcomplete_cwd falls through to the editor cwd"] = function()
  vim.env.AGENTCOMPLETE_CWD = nil
  vim.g.agentcomplete_cwd = ""
  local cc = require "agentcomplete.detect.claude_code"
  local s = assert(cc.detect(named_buf "/tmp/ac-h/claude-prompt-h.md"))
  expect.equality(s.cwd, vim.loop.cwd())
end

T["claude_code"]["derives project-local skill/command dirs from the resolved cwd"] = function()
  vim.env.AGENTCOMPLETE_CWD = "/tmp/projX"
  vim.g.agentcomplete_cwd = nil
  local cc = require "agentcomplete.detect.claude_code"
  local s = assert(cc.detect(named_buf "/tmp/ac-g/claude-prompt-g.md"))
  expect.equality(vim.tbl_contains(s.skill_dirs, "/tmp/projX/.claude/skills"), true)
  expect.equality(vim.tbl_contains(s.command_dirs, "/tmp/projX/.claude/commands"), true)
end

T["opencode"] = new_set()

T["opencode"]["matches a <millis>.md buffer when OPENCODE=1, rooted at cwd"] = function()
  vim.env.AGENTCOMPLETE_CWD = nil
  vim.g.agentcomplete_cwd = nil
  vim.env.OPENCODE = "1"
  vim.env.OPENCODE_PID = "12345"
  local buf = named_buf "/private/tmp/1718646000001.md"
  local oc = require "agentcomplete.detect.opencode"
  local s = assert(oc.detect(buf))
  expect.equality(s.tool, "opencode")
  expect.equality(s.session_id, "12345")
  expect.equality(s.cwd, vim.loop.cwd())
  expect.equality(#s.skill_dirs > 0, true)
  expect.equality(#s.command_dirs > 0, true)
end

T["opencode"]["ignores every buffer when OPENCODE is not set"] = function()
  vim.env.OPENCODE = nil
  vim.env.OPENCODE_PID = nil
  local oc = require "agentcomplete.detect.opencode"
  expect.equality(oc.detect(named_buf "/private/tmp/1718646000002.md"), nil)
end

T["opencode"]["ignores non-opencode-shaped names even when OPENCODE=1"] = function()
  vim.env.OPENCODE = "1"
  local oc = require "agentcomplete.detect.opencode"
  expect.equality(oc.detect(named_buf "/tmp/oc-a/notes.md"), nil) -- non-digit basename
  expect.equality(oc.detect(named_buf "/tmp/oc-b/123.txt"), nil) -- wrong extension
  expect.equality(oc.detect(named_buf "/tmp/oc-c/12a45.md"), nil) -- not all digits
  expect.equality(oc.detect(named_buf ""), nil) -- unnamed buffer
end

T["opencode"]["AGENTCOMPLETE_CWD overrides the editor cwd"] = function()
  vim.env.OPENCODE = "1"
  vim.env.AGENTCOMPLETE_CWD = "/tmp/projEnvO"
  vim.g.agentcomplete_cwd = nil
  local oc = require "agentcomplete.detect.opencode"
  local s = assert(oc.detect(named_buf "/private/tmp/1718646000003.md"))
  expect.equality(s.cwd, "/tmp/projEnvO")
end

T["opencode"]["derives project-local skill/command dirs from the resolved cwd"] = function()
  vim.env.OPENCODE = "1"
  vim.env.AGENTCOMPLETE_CWD = "/tmp/projXO"
  vim.g.agentcomplete_cwd = nil
  local oc = require "agentcomplete.detect.opencode"
  local s = assert(oc.detect(named_buf "/private/tmp/1718646000004.md"))
  expect.equality(vim.tbl_contains(s.skill_dirs, "/tmp/projXO/.opencode/skill"), true)
  expect.equality(vim.tbl_contains(s.command_dirs, "/tmp/projXO/.opencode/command"), true)
end

T["opencode"]["populates extra_commands from the project opencode.json command map"] = function()
  vim.env.OPENCODE = "1"
  vim.g.agentcomplete_cwd = nil
  vim.env.XDG_CONFIG_HOME = tmpdir() -- isolate the global config home
  vim.env.OPENCODE_CONFIG = nil
  vim.env.OPENCODE_CONFIG_DIR = nil
  local proj = tmpdir()
  write(proj .. "/opencode.json", { '{ "command": { "release": { "description": "Cut a release" } } }' })
  vim.env.AGENTCOMPLETE_CWD = proj
  local oc = require "agentcomplete.detect.opencode"
  local s = assert(oc.detect(named_buf "/private/tmp/1718646000005.md"))
  local by = {}
  for _, c in ipairs(s.extra_commands or {}) do
    by[c.name] = c
  end
  expect.equality(by.release ~= nil, true)
  expect.equality(by.release.description, "Cut a release")
end

T["opencode"]["surfaces OpenCode built-in commands in extra_commands"] = function()
  vim.env.OPENCODE = "1"
  vim.g.agentcomplete_cwd = nil
  vim.env.XDG_CONFIG_HOME = tmpdir() -- isolate the global config home (no commands)
  vim.env.OPENCODE_CONFIG = nil
  vim.env.OPENCODE_CONFIG_DIR = nil
  vim.env.AGENTCOMPLETE_CWD = tmpdir() -- project with no opencode.json / command files
  local oc = require "agentcomplete.detect.opencode"
  local s = assert(oc.detect(named_buf "/private/tmp/1718646000006.md"))
  local names = {}
  for _, c in ipairs(s.extra_commands or {}) do
    names[c.name] = true
  end
  expect.equality(names.init, true) -- `/init` is a built-in OpenCode command, not a file/config command
end

T["opencode"]["orders config-map commands before built-in commands"] = function()
  vim.env.OPENCODE = "1"
  vim.g.agentcomplete_cwd = nil
  vim.env.XDG_CONFIG_HOME = tmpdir()
  vim.env.OPENCODE_CONFIG = nil
  vim.env.OPENCODE_CONFIG_DIR = nil
  local proj = tmpdir()
  write(proj .. "/opencode.json", { '{ "command": { "deploy": { "description": "Ship it" } } }' })
  vim.env.AGENTCOMPLETE_CWD = proj
  local oc = require "agentcomplete.detect.opencode"
  local s = assert(oc.detect(named_buf "/private/tmp/1718646000007.md"))
  -- config-map "deploy" must precede any built-in (e.g. "init") so a user's config command
  -- wins the name-dedup in sources.items.
  local idx_deploy, idx_init
  for i, c in ipairs(s.extra_commands) do
    if c.name == "deploy" then
      idx_deploy = i
    elseif c.name == "init" then
      idx_init = i
    end
  end
  expect.equality(idx_deploy ~= nil and idx_init ~= nil, true)
  expect.equality(idx_deploy < idx_init, true)
end

return T
