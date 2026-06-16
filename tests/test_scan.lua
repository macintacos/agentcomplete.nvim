-- Tests for agentcomplete.scan: filesystem discovery of skills, commands, files.
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

-- Isolate each case from ambient git env (e.g. GIT_DIR set inside a pre-push
-- hook), which would otherwise redirect the fixture's `git init` and
-- scan.files' git calls at the surrounding repository.
local GIT_ENV = { "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY" }
local saved_git = {}
local T = new_set {
  hooks = {
    pre_case = function()
      for _, k in ipairs(GIT_ENV) do
        saved_git[k] = vim.env[k]
        vim.env[k] = nil
      end
    end,
    post_case = function()
      for _, k in ipairs(GIT_ENV) do
        vim.env[k] = saved_git[k]
      end
    end,
  },
}

T["skills"] = new_set()

T["skills"]["discovers skills, reading name + description from frontmatter"] = function()
  local scan = require "agentcomplete.scan"
  local root = tmpdir()
  write(root .. "/skills/foo/SKILL.md", { "---", "name: foo", "description: Does foo things", "---", "# Foo" })
  local skills = scan.skills { root .. "/skills" }
  expect.equality(#skills, 1)
  expect.equality(skills[1].name, "foo")
  expect.equality(skills[1].description, "Does foo things")
end

T["skills"]["falls back to directory name when frontmatter lacks name"] = function()
  local scan = require "agentcomplete.scan"
  local root = tmpdir()
  write(root .. "/skills/bar-baz/SKILL.md", { "---", "description: No name here", "---" })
  local skills = scan.skills { root .. "/skills" }
  expect.equality(#skills, 1)
  expect.equality(skills[1].name, "bar-baz")
end

T["skills"]["returns empty for a missing directory"] = function()
  local scan = require "agentcomplete.scan"
  expect.equality(scan.skills { "/nope/does/not/exist" }, {})
end

T["commands"] = new_set()

T["commands"]["discovers flat and nested commands (nested joined with ':')"] = function()
  local scan = require "agentcomplete.scan"
  local root = tmpdir()
  write(root .. "/commands/deploy.md", { "---", "description: Deploy it", "---" })
  write(root .. "/commands/git/commit.md", { "# commit" })
  local cmds = scan.commands { root .. "/commands" }
  table.sort(cmds, function(a, b)
    return a.name < b.name
  end)
  expect.equality(#cmds, 2)
  expect.equality(cmds[1].name, "deploy")
  expect.equality(cmds[1].description, "Deploy it")
  expect.equality(cmds[2].name, "git:commit")
end

T["files"] = new_set()

T["files"]["lists files recursively (non-git dir → scandir fallback)"] = function()
  local scan = require "agentcomplete.scan"
  local root = tmpdir()
  write(root .. "/src/init.lua", { "" })
  write(root .. "/src/util/helpers.lua", { "" })
  write(root .. "/README.md", { "" })
  local files = scan.files(root)
  table.sort(files)
  expect.equality(files, { "README.md", "src/init.lua", "src/util/helpers.lua" })
end

T["files"]["respects .gitignore inside a git work-tree"] = function()
  local scan = require "agentcomplete.scan"
  local root = tmpdir()
  write(root .. "/keep.lua", { "" })
  write(root .. "/ignored.log", { "" })
  write(root .. "/.gitignore", { "*.log" })
  vim.fn.system { "git", "-C", root, "init", "-q" }
  local files = scan.files(root)
  table.sort(files)
  -- .gitignore is itself tracked-able but uninteresting; assert the ignored file is excluded and the kept one present.
  expect.equality(vim.tbl_contains(files, "keep.lua"), true)
  expect.equality(vim.tbl_contains(files, "ignored.log"), false)
end

return T
