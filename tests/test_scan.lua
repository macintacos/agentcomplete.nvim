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
local saved_claude_config
local saved_opencode_config
local saved_opencode_config_file
local saved_xdg_config
local T = new_set {
  hooks = {
    pre_case = function()
      for _, k in ipairs(GIT_ENV) do
        saved_git[k] = vim.env[k]
        vim.env[k] = nil
      end
      saved_claude_config = vim.env.CLAUDE_CONFIG_DIR
      saved_opencode_config = vim.env.OPENCODE_CONFIG_DIR
      saved_opencode_config_file = vim.env.OPENCODE_CONFIG
      saved_xdg_config = vim.env.XDG_CONFIG_HOME
    end,
    post_case = function()
      for _, k in ipairs(GIT_ENV) do
        vim.env[k] = saved_git[k]
      end
      vim.env.CLAUDE_CONFIG_DIR = saved_claude_config
      vim.env.OPENCODE_CONFIG_DIR = saved_opencode_config
      vim.env.OPENCODE_CONFIG = saved_opencode_config_file
      vim.env.XDG_CONFIG_HOME = saved_xdg_config
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

T["claude_dirs"] = new_set()

T["claude_dirs"]["always includes global (CLAUDE_CONFIG_DIR) and project-local dirs"] = function()
  local scan = require "agentcomplete.scan"
  local home = tmpdir()
  vim.env.CLAUDE_CONFIG_DIR = home
  local skill_dirs, command_dirs = scan.claude_dirs "/tmp/projY"
  expect.equality(vim.tbl_contains(skill_dirs, home .. "/skills"), true)
  expect.equality(vim.tbl_contains(command_dirs, home .. "/commands"), true)
  expect.equality(vim.tbl_contains(skill_dirs, "/tmp/projY/.claude/skills"), true)
  expect.equality(vim.tbl_contains(command_dirs, "/tmp/projY/.claude/commands"), true)
end

T["claude_dirs"]["includes enabled plugin dirs from installed_plugins.json"] = function()
  local scan = require "agentcomplete.scan"
  local home = tmpdir()
  vim.env.CLAUDE_CONFIG_DIR = home
  local install_path = home .. "/plugins/cache/mp/plug/1.0"
  write(home .. "/plugins/installed_plugins.json", {
    vim.json.encode {
      version = 2,
      plugins = { ["plug@mp"] = { { installPath = install_path, scope = "user" } } },
    },
  })
  local skill_dirs, command_dirs = scan.claude_dirs "/tmp/projY"
  expect.equality(vim.tbl_contains(skill_dirs, install_path .. "/skills"), true)
  expect.equality(vim.tbl_contains(command_dirs, install_path .. "/commands"), true)
end

T["claude_dirs"]["tolerates a missing installed_plugins.json"] = function()
  local scan = require "agentcomplete.scan"
  local home = tmpdir() -- no plugins/ subtree
  vim.env.CLAUDE_CONFIG_DIR = home
  local skill_dirs = scan.claude_dirs "/tmp/projY"
  expect.equality(vim.tbl_contains(skill_dirs, home .. "/skills"), true)
end

T["claude_dirs"]["de-duplicates when project-local equals global (claude launched from a config parent)"] = function()
  local scan = require "agentcomplete.scan"
  local root = tmpdir()
  vim.env.CLAUDE_CONFIG_DIR = root .. "/.claude"
  -- cwd == root ⇒ project-local `<root>/.claude/skills` is the same path as global.
  local skill_dirs, command_dirs = scan.claude_dirs(root)
  local function count(list, want)
    local n = 0
    for _, v in ipairs(list) do
      if v == want then
        n = n + 1
      end
    end
    return n
  end
  expect.equality(count(skill_dirs, root .. "/.claude/skills"), 1)
  expect.equality(count(command_dirs, root .. "/.claude/commands"), 1)
end

T["opencode_dirs"] = new_set()

T["opencode_dirs"]["includes global (XDG) and project-local skill/command dirs"] = function()
  local scan = require "agentcomplete.scan"
  local xdg = tmpdir()
  vim.env.XDG_CONFIG_HOME = xdg
  vim.env.OPENCODE_CONFIG_DIR = nil
  local skill_dirs, command_dirs = scan.opencode_dirs "/tmp/projO"
  -- OpenCode discovers skills as {skill,skills}/**/SKILL.md, so both subdir names are searched.
  expect.equality(vim.tbl_contains(skill_dirs, xdg .. "/opencode/skill"), true)
  expect.equality(vim.tbl_contains(skill_dirs, xdg .. "/opencode/skills"), true)
  expect.equality(vim.tbl_contains(command_dirs, xdg .. "/opencode/command"), true)
  expect.equality(vim.tbl_contains(skill_dirs, "/tmp/projO/.opencode/skill"), true)
  expect.equality(vim.tbl_contains(command_dirs, "/tmp/projO/.opencode/command"), true)
end

T["opencode_dirs"]["falls back to ~/.config/opencode when XDG_CONFIG_HOME is unset"] = function()
  local scan = require "agentcomplete.scan"
  vim.env.XDG_CONFIG_HOME = nil
  vim.env.OPENCODE_CONFIG_DIR = nil
  local skill_dirs = scan.opencode_dirs "/tmp/projO"
  local home = vim.fn.expand "~/.config/opencode"
  expect.equality(vim.tbl_contains(skill_dirs, home .. "/skill"), true)
end

T["opencode_dirs"]["honors OPENCODE_CONFIG_DIR as an extra base"] = function()
  local scan = require "agentcomplete.scan"
  local extra = tmpdir()
  vim.env.OPENCODE_CONFIG_DIR = extra
  local skill_dirs, command_dirs = scan.opencode_dirs "/tmp/projO"
  expect.equality(vim.tbl_contains(skill_dirs, extra .. "/skill"), true)
  expect.equality(vim.tbl_contains(command_dirs, extra .. "/command"), true)
end

T["opencode_dirs"]["de-duplicates when project-local equals OPENCODE_CONFIG_DIR"] = function()
  local scan = require "agentcomplete.scan"
  local root = tmpdir()
  vim.env.XDG_CONFIG_HOME = nil
  -- cwd's project-local `<root>/.opencode` is the same base as OPENCODE_CONFIG_DIR.
  vim.env.OPENCODE_CONFIG_DIR = root .. "/.opencode"
  local skill_dirs, command_dirs = scan.opencode_dirs(root)
  local function count(list, want)
    local n = 0
    for _, v in ipairs(list) do
      if v == want then
        n = n + 1
      end
    end
    return n
  end
  expect.equality(count(skill_dirs, root .. "/.opencode/skill"), 1)
  expect.equality(count(command_dirs, root .. "/.opencode/command"), 1)
end

T["opencode_commands"] = new_set()

-- Isolate the global config home to an empty dir so tests never read the dev's
-- real ~/.config/opencode, and clear the file/dir overrides.
local function isolate_opencode_config()
  vim.env.XDG_CONFIG_HOME = tmpdir()
  vim.env.OPENCODE_CONFIG = nil
  vim.env.OPENCODE_CONFIG_DIR = nil
end

T["opencode_commands"]["reads the command map from opencode.json at the project root"] = function()
  local scan = require "agentcomplete.scan"
  isolate_opencode_config()
  local root = tmpdir()
  write(root .. "/opencode.json", {
    "{",
    '  "command": {',
    '    "deploy": { "description": "Ship it", "template": "deploy $ARGUMENTS" },',
    '    "test": { "template": "run tests" }',
    "  }",
    "}",
  })
  local cmds = scan.opencode_commands(root)
  local by = {}
  for _, c in ipairs(cmds) do
    by[c.name] = c
  end
  expect.equality(by.deploy.description, "Ship it")
  expect.equality(by.test ~= nil, true)
end

T["opencode_commands"]["tolerates JSONC comments and trailing commas"] = function()
  local scan = require "agentcomplete.scan"
  isolate_opencode_config()
  local root = tmpdir()
  write(root .. "/opencode.jsonc", {
    "{",
    "  // user commands",
    '  "command": {',
    '    "build": { "description": "Build", }, /* block comment */',
    "  },",
    "}",
  })
  local cmds = scan.opencode_commands(root)
  expect.equality(#cmds, 1)
  expect.equality(cmds[1].name, "build")
  expect.equality(cmds[1].description, "Build")
end

T["opencode_commands"]["preserves commas/brackets inside string values"] = function()
  local scan = require "agentcomplete.scan"
  isolate_opencode_config()
  local root = tmpdir()
  -- The description contains `,]` — trailing-comma stripping must not touch it.
  write(root .. "/opencode.json", { '{ "command": { "x": { "description": "tuple [a,] ok" } } }' })
  local cmds = scan.opencode_commands(root)
  expect.equality(cmds[1].description, "tuple [a,] ok")
end

T["opencode_commands"]["empty when there is no config or no command map"] = function()
  local scan = require "agentcomplete.scan"
  isolate_opencode_config()
  local root = tmpdir()
  expect.equality(scan.opencode_commands(root), {})
  write(root .. "/opencode.json", { '{ "model": "anthropic/claude" }' })
  expect.equality(scan.opencode_commands(root), {})
end

T["opencode_commands"]["malformed config yields empty, not an error"] = function()
  local scan = require "agentcomplete.scan"
  isolate_opencode_config()
  local root = tmpdir()
  write(root .. "/opencode.json", { "{ this is not json" })
  expect.equality(scan.opencode_commands(root), {})
end

T["opencode_commands"]["de-duplicates a command defined in both global and project config"] = function()
  local scan = require "agentcomplete.scan"
  isolate_opencode_config()
  local xdg = tmpdir()
  vim.env.XDG_CONFIG_HOME = xdg
  local root = tmpdir()
  write(xdg .. "/opencode/opencode.json", { '{ "command": { "deploy": { "description": "global" } } }' })
  write(root .. "/opencode.json", { '{ "command": { "deploy": { "description": "project" } } }' })
  local n = 0
  for _, c in ipairs(scan.opencode_commands(root)) do
    if c.name == "deploy" then
      n = n + 1
    end
  end
  expect.equality(n, 1)
end

T["opencode_builtin_commands"] = new_set()

T["opencode_builtin_commands"]["includes built-in TUI commands (shown and hidden alike)"] = function()
  local scan = require "agentcomplete.scan"
  local by = {}
  for _, c in ipairs(scan.opencode_builtin_commands()) do
    by[c.name] = c
  end
  expect.equality(by.init ~= nil, true)
  expect.equality(by.undo ~= nil, true)
  expect.equality(by.help ~= nil, true)
  expect.equality(by.editor ~= nil, true)
end

T["opencode_builtin_commands"]["hides interactive commands and shows conversation actions"] = function()
  local scan = require "agentcomplete.scan"
  local by = {}
  for _, c in ipairs(scan.opencode_builtin_commands()) do
    by[c.name] = c
  end
  -- discrete conversation/session actions are shown by default
  expect.equality(by.init.hidden ~= true, true)
  expect.equality(by.undo.hidden ~= true, true)
  -- interactive TUI affordances (dialogs/pickers/toggles/lifecycle) are hidden by default
  expect.equality(by.help.hidden, true)
  expect.equality(by.editor.hidden, true)
  expect.equality(by.models.hidden, true)
end

T["opencode_builtin_commands"]["every entry has a non-empty name and description"] = function()
  local scan = require "agentcomplete.scan"
  local cmds = scan.opencode_builtin_commands()
  expect.equality(#cmds > 0, true)
  for _, c in ipairs(cmds) do
    expect.equality(type(c.name) == "string" and c.name ~= "", true)
    expect.equality(type(c.description) == "string" and c.description ~= "", true)
  end
end

return T
