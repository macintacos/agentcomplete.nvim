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

return T
