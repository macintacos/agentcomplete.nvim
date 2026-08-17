-- Tests for agentcomplete.highlight: which tokens resolve, and to which group.
local MiniTest = require "mini.test"
local new_set = MiniTest.new_set
local expect = MiniTest.expect

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

local function write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

---A session over a tmpdir holding one skill, one command, and a `src/` tree.
local function fixture_session()
  local root = tmpdir()
  write(root .. "/skills/deploy-helper/SKILL.md", { "---", "name: deploy-helper", "description: Helps deploy", "---" })
  write(root .. "/commands/deploy.md", { "---", "description: Deploy it", "---" })
  write(root .. "/src/init.lua", { "" })
  return {
    tool = "claude-code",
    cwd = root,
    skill_dirs = { root .. "/skills" },
    command_dirs = { root .. "/commands" },
  }
end

local T = new_set()

T["marks"] = new_set()

T["marks"]["a resolving skill token is marked as a skill"] = function()
  local highlight = require "agentcomplete.highlight"
  local marks = highlight.marks(fixture_session(), { "/deploy-helper" })
  expect.equality(#marks, 1)
  expect.equality(marks[1], { row = 0, col = 0, end_col = 14, hl_group = "AgentCompleteSkill" })
end

T["marks"]["a resolving command token is marked as a skill"] = function()
  local highlight = require "agentcomplete.highlight"
  local marks = highlight.marks(fixture_session(), { "run /deploy now" })
  expect.equality(#marks, 1)
  expect.equality(marks[1], { row = 0, col = 4, end_col = 11, hl_group = "AgentCompleteSkill" })
end

T["marks"]["an unresolvable skill token is not marked"] = function()
  local highlight = require "agentcomplete.highlight"
  expect.equality(highlight.marks(fixture_session(), { "/nope" }), {})
end

T["marks"]["a resolving file token is marked as a file"] = function()
  local highlight = require "agentcomplete.highlight"
  local marks = highlight.marks(fixture_session(), { "@src/init.lua" })
  expect.equality(#marks, 1)
  expect.equality(marks[1], { row = 0, col = 0, end_col = 13, hl_group = "AgentCompleteFile" })
end

T["marks"]["a directory resolves, unlike @ completion"] = function()
  local highlight = require "agentcomplete.highlight"
  local marks = highlight.marks(fixture_session(), { "@src" })
  expect.equality(#marks, 1)
  expect.equality(marks[1].hl_group, "AgentCompleteFile")
end

T["marks"]["an absolute path resolves without being joined to cwd"] = function()
  local highlight = require "agentcomplete.highlight"
  local session = fixture_session()
  session.cwd = "/nowhere" -- the join would fail; only normalization can resolve this
  local marks = highlight.marks(session, { "@" .. tmpdir() })
  expect.equality(#marks, 1)
  expect.equality(marks[1].hl_group, "AgentCompleteFile")
end

T["marks"]["a nonexistent path is not marked"] = function()
  local highlight = require "agentcomplete.highlight"
  expect.equality(highlight.marks(fixture_session(), { "@missing.lua" }), {})
end

T["marks"]["a bare trigger never resolves"] = function()
  local highlight = require "agentcomplete.highlight"
  expect.equality(highlight.marks(fixture_session(), { "@ /" }), {})
end

T["marks"]["a gitignored file resolves even though scan.files omits it"] = function()
  local highlight = require "agentcomplete.highlight"
  local scan = require "agentcomplete.scan"
  local session = fixture_session()
  write(session.cwd .. "/.gitignore", { "secret.txt" })
  write(session.cwd .. "/secret.txt", { "shh" })
  vim.fn.system { "git", "-C", session.cwd, "init", "-q" }
  expect.equality(vim.tbl_contains(scan.files(session.cwd), "secret.txt"), false)
  local marks = highlight.marks(session, { "@secret.txt" })
  expect.equality(#marks, 1)
  expect.equality(marks[1].hl_group, "AgentCompleteFile")
end

T["marks"]["resolution happens at paint time, not when the session was built"] = function()
  local highlight = require "agentcomplete.highlight"
  local session = fixture_session()
  expect.equality(highlight.marks(session, { "@later.lua" }), {})
  write(session.cwd .. "/later.lua", { "" })
  expect.equality(#highlight.marks(session, { "@later.lua" }), 1)
end

T["marks"]["mid-word triggers are not marked"] = function()
  local highlight = require "agentcomplete.highlight"
  local session = fixture_session()
  write(session.cwd .. "/foo/bar", { "" })
  expect.equality(highlight.marks(session, { "foo/bar julian@excessive.dev" }), {})
end

T["marks"]["skill and file tokens use different groups"] = function()
  local highlight = require "agentcomplete.highlight"
  local marks = highlight.marks(fixture_session(), { "/deploy", "@src/init.lua" })
  expect.equality(#marks, 2)
  expect.equality(marks[1].row, 0)
  expect.equality(marks[2].row, 1)
  expect.equality(marks[1].hl_group ~= marks[2].hl_group, true)
end

T["marks"]["honors session.sources toggles"] = function()
  local highlight = require "agentcomplete.highlight"
  local lines = { "/deploy @src/init.lua" }

  local session = fixture_session()
  session.sources = { slash = false, file = true }
  local files_only = highlight.marks(session, lines)
  expect.equality(#files_only, 1)
  expect.equality(files_only[1].hl_group, "AgentCompleteFile")

  session.sources = { slash = true, file = false }
  local skills_only = highlight.marks(session, lines)
  expect.equality(#skills_only, 1)
  expect.equality(skills_only[1].hl_group, "AgentCompleteSkill")
end

---The extmarks actually applied to `buf`, in `M.marks` shape.
local function painted(buf)
  local ns = require("agentcomplete.highlight").ns
  return vim.tbl_map(function(m)
    return { row = m[2], col = m[3], end_col = m[4].end_col, hl_group = m[4].hl_group }
  end, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }))
end

---A named scratch buffer holding `lines`. The fixture root is a fresh tmpdir per
---call, so buffer names never collide across cases.
local function named_buf(name, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

---A Claude Code prompt buffer attached over a `fixture_session` root, which doubles as
---`$CLAUDE_CONFIG_DIR` so the fixture's own skills/commands stand in for the real `~/.claude`.
---@return integer buf
---@return string root
local function attached_claude_buf(lines)
  local root = fixture_session().cwd
  vim.env.CLAUDE_CONFIG_DIR = root
  vim.g.agentcomplete_cwd = root
  local buf = named_buf(root .. "/claude-prompt-ac.md", lines)
  expect.equality(require("agentcomplete").attach(buf), true)
  return buf, root
end

local saved = {}
T["attach"] = new_set {
  hooks = {
    pre_case = function()
      saved = {
        cwd = vim.g.agentcomplete_cwd,
        env_cwd = vim.env.AGENTCOMPLETE_CWD,
        claude_home = vim.env.CLAUDE_CONFIG_DIR,
        opencode = vim.env.OPENCODE,
        opencode_config = vim.env.OPENCODE_CONFIG,
        opencode_config_dir = vim.env.OPENCODE_CONFIG_DIR,
        xdg = vim.env.XDG_CONFIG_HOME,
        config = require("agentcomplete").config,
      }
      vim.env.AGENTCOMPLETE_CWD = nil
      vim.env.OPENCODE = nil
      vim.env.OPENCODE_CONFIG = nil
      vim.env.OPENCODE_CONFIG_DIR = nil
      -- Exactly the two built-in detectors: test_detect leaves its own in the registry.
      require("agentcomplete.detect").clear()
      require("agentcomplete").setup { opencode = { resolve_via_cli = false } }
    end,
    post_case = function()
      -- Wipe the case's buffer so its augroup and `_sessions` entry do not outlive it.
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf):match "%.md$" then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
      vim.g.agentcomplete_cwd = saved.cwd
      vim.env.AGENTCOMPLETE_CWD = saved.env_cwd
      vim.env.CLAUDE_CONFIG_DIR = saved.claude_home
      vim.env.OPENCODE = saved.opencode
      vim.env.OPENCODE_CONFIG = saved.opencode_config
      vim.env.OPENCODE_CONFIG_DIR = saved.opencode_config_dir
      vim.env.XDG_CONFIG_HOME = saved.xdg
      require("agentcomplete").config = saved.config
    end,
  },
}

T["attach"]["a Claude Code prompt buffer paints both groups"] = function()
  local buf = attached_claude_buf { "/deploy @src/init.lua" }
  expect.equality(painted(buf), {
    { row = 0, col = 0, end_col = 7, hl_group = "AgentCompleteSkill" },
    { row = 0, col = 8, end_col = 21, hl_group = "AgentCompleteFile" },
  })
end

T["attach"]["an OpenCode prompt buffer paints both groups"] = function()
  local root = fixture_session().cwd
  vim.env.XDG_CONFIG_HOME = tmpdir() -- isolate the global opencode config home
  vim.env.OPENCODE_CONFIG_DIR = root -- `<root>/skills` is an OpenCode skill dir
  vim.env.OPENCODE = "1"
  vim.g.agentcomplete_cwd = root
  local buf = named_buf(root .. "/1234567890.md", { "/deploy-helper @src/init.lua" })
  expect.equality(require("agentcomplete").attach(buf), true)
  expect.equality(painted(buf), {
    { row = 0, col = 0, end_col = 14, hl_group = "AgentCompleteSkill" },
    { row = 0, col = 15, end_col = 28, hl_group = "AgentCompleteFile" },
  })
end

T["attach"]["a file created after attach paints on the next repaint"] = function()
  local buf, root = attached_claude_buf { "@later.lua" }
  expect.equality(painted(buf), {})
  write(root .. "/later.lua", { "" })
  require("agentcomplete.highlight").repaint(buf)
  expect.equality(painted(buf), { { row = 0, col = 0, end_col = 10, hl_group = "AgentCompleteFile" } })
end

T["attach"]["a highlighted token is exempt from spell checking, the prose around it is not"] = function()
  local buf = attached_claude_buf { "run /deploy now" }
  -- The mark spans exactly the token, so 'spell' still applies to the prose around it.
  expect.equality(painted(buf), { { row = 0, col = 4, end_col = 11, hl_group = "AgentCompleteSkill" } })
  local ns = require("agentcomplete.highlight").ns
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  expect.equality(marks[1][4].spell, false)
end

T["attach"]["detach clears every mark"] = function()
  local buf = attached_claude_buf { "@src/init.lua" }
  expect.equality(#painted(buf), 1)
  require("agentcomplete").detach(buf)
  expect.equality(vim.api.nvim_buf_get_extmarks(buf, require("agentcomplete.highlight").ns, 0, -1, {}), {})
end

T["ensure_groups"] = new_set()

T["ensure_groups"]["links both groups to distinct built-ins"] = function()
  local highlight = require "agentcomplete.highlight"
  highlight.ensure_groups()
  local skill = vim.api.nvim_get_hl(0, { name = "AgentCompleteSkill" })
  local file = vim.api.nvim_get_hl(0, { name = "AgentCompleteFile" })
  expect.equality(type(skill.link), "string")
  expect.equality(type(file.link), "string")
  expect.equality(skill.link ~= file.link, true)
end

-- The property that lets the module ship without a `ColorScheme` autocmd: `:colorscheme`
-- runs `:hi clear`, and a `default = true` link is exactly what survives it.
T["ensure_groups"]["the default links survive a colorscheme change"] = function()
  local highlight = require "agentcomplete.highlight"
  local previous = vim.g.colors_name
  highlight.ensure_groups()
  vim.cmd "colorscheme habamax"
  expect.equality(vim.api.nvim_get_hl(0, { name = "AgentCompleteSkill" }).link, "Special")
  expect.equality(vim.api.nvim_get_hl(0, { name = "AgentCompleteFile" }).link, "Directory")
  vim.cmd("colorscheme " .. (previous or "default"))
end

return T
