-- Tests for agentcomplete.sources: backend-agnostic context parsing + item assembly.
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

local T = new_set()

T["context"] = new_set()

T["context"]["detects a slash trigger at start of line"] = function()
  local sources = require "agentcomplete.sources"
  local ctx = assert(sources.context("/fo", 3))
  expect.equality(ctx.trigger, "/")
  expect.equality(ctx.query, "fo")
  expect.equality(ctx.start_col, 1) -- 0-based byte column where the query ("fo") begins
end

T["context"]["detects a slash trigger after whitespace"] = function()
  local sources = require "agentcomplete.sources"
  local ctx = assert(sources.context("see /dep", 8))
  expect.equality(ctx.trigger, "/")
  expect.equality(ctx.query, "dep")
  expect.equality(ctx.start_col, 5)
end

T["context"]["detects an at trigger and keeps path separators in the query"] = function()
  local sources = require "agentcomplete.sources"
  local ctx = assert(sources.context("@src/ba", 7))
  expect.equality(ctx.trigger, "@")
  expect.equality(ctx.query, "src/ba")
  expect.equality(ctx.start_col, 1)
end

T["context"]["empty query right after a bare trigger"] = function()
  local sources = require "agentcomplete.sources"
  local ctx = assert(sources.context("/", 1))
  expect.equality(ctx.trigger, "/")
  expect.equality(ctx.query, "")
end

T["context"]["no trigger when the char is mid-word (foo/bar)"] = function()
  local sources = require "agentcomplete.sources"
  expect.equality(sources.context("foo/bar", 7), nil)
end

T["context"]["no trigger for plain text"] = function()
  local sources = require "agentcomplete.sources"
  expect.equality(sources.context("hello world", 11), nil)
end

T["tokens"] = new_set()

T["tokens"]["returns both trigger tokens on a line with their columns"] = function()
  local sources = require "agentcomplete.sources"
  local toks = sources.tokens "see /deploy and @src/init.lua"
  expect.equality(#toks, 2)
  expect.equality(toks[1], { trigger = "/", name = "deploy", col = 4, end_col = 11 })
  expect.equality(toks[2], { trigger = "@", name = "src/init.lua", col = 16, end_col = 29 })
end

T["tokens"]["ignores mid-word triggers"] = function()
  local sources = require "agentcomplete.sources"
  expect.equality(sources.tokens "foo/bar julian@excessive.dev", {})
end

T["tokens"]["a bare trigger is a token with an empty name"] = function()
  local sources = require "agentcomplete.sources"
  local toks = sources.tokens "@"
  expect.equality(#toks, 1)
  expect.equality(toks[1], { trigger = "@", name = "", col = 0, end_col = 1 })
end

T["tokens"]["trailing prose punctuation is not part of the token"] = function()
  local sources = require "agentcomplete.sources"
  local toks = sources.tokens "see @src/init.lua, then run /deploy."
  expect.equality(#toks, 2)
  expect.equality(toks[1], { trigger = "@", name = "src/init.lua", col = 4, end_col = 17 })
  expect.equality(toks[2], { trigger = "/", name = "deploy", col = 28, end_col = 35 })
end

T["tokens"]["trims a run of closing punctuation"] = function()
  local sources = require "agentcomplete.sources"
  local toks = sources.tokens "@src/init.lua))."
  expect.equality(#toks, 1)
  expect.equality(toks[1].name, "src/init.lua")
end

T["tokens"]["leading whitespace does not shift the columns"] = function()
  local sources = require "agentcomplete.sources"
  local toks = sources.tokens "   /deploy"
  expect.equality(#toks, 1)
  expect.equality(toks[1], { trigger = "/", name = "deploy", col = 3, end_col = 10 })
end

T["items"] = new_set()

local function fixture_session()
  local root = tmpdir()
  write(root .. "/skills/deploy-helper/SKILL.md", { "---", "name: deploy-helper", "description: Helps deploy", "---" })
  write(root .. "/commands/deploy.md", { "---", "description: Deploy it", "---" })
  write(root .. "/src/init.lua", { "" })
  write(root .. "/src/main.lua", { "" })
  return {
    tool = "claude-code",
    cwd = root,
    skill_dirs = { root .. "/skills" },
    command_dirs = { root .. "/commands" },
  }
end

T["items"]["slash trigger returns skills + commands matching the query prefix"] = function()
  local sources = require "agentcomplete.sources"
  local session = fixture_session()
  local items = sources.items(session, { trigger = "/", query = "dep", start_col = 1 })
  local labels = vim.tbl_map(function(i)
    return i.label
  end, items)
  table.sort(labels)
  expect.equality(labels, { "/deploy", "/deploy-helper" })
  -- normalized item shape
  local by_label = {}
  for _, i in ipairs(items) do
    by_label[i.label] = i
  end
  expect.equality(by_label["/deploy"].insert_text, "deploy")
  expect.equality(by_label["/deploy"].kind, "command")
  expect.equality(by_label["/deploy"].detail, "Deploy it")
  expect.equality(by_label["/deploy-helper"].kind, "skill")
end

-- Skills and commands share the `/` namespace, so a name held by both must be offered once
-- rather than as two visually identical entries the user can't tell apart.
T["items"]["a skill and a command of the same name are offered once"] = function()
  local sources = require "agentcomplete.sources"
  local root = tmpdir()
  write(root .. "/skills/deploy/SKILL.md", { "---", "name: deploy", "description: The skill", "---" })
  write(root .. "/commands/deploy.md", { "---", "description: The command", "---" })
  local items = sources.items({
    tool = "claude-code",
    cwd = root,
    skill_dirs = { root .. "/skills" },
    command_dirs = { root .. "/commands" },
  }, { trigger = "/", query = "", start_col = 1 })
  expect.equality(#items, 1)
  expect.equality(items[1].kind, "skill") -- skills are added first, so they win the clash
  expect.equality(items[1].detail, "The skill")
end

T["items"]["slash trigger includes session.extra_commands, deduped against markdown commands"] = function()
  local sources = require "agentcomplete.sources"
  local session = fixture_session()
  -- "ship" is config-only; "deploy" also exists as a markdown command (deploy.md).
  session.extra_commands = {
    { name = "ship", description = "From config" },
    { name = "deploy", description = "config dup of the markdown command" },
  }
  local items = sources.items(session, { trigger = "/", query = "", start_col = 1 })
  local labels = vim.tbl_map(function(i)
    return i.label
  end, items)
  expect.equality(vim.tbl_contains(labels, "/ship"), true)
  local n_deploy = 0
  for _, l in ipairs(labels) do
    if l == "/deploy" then
      n_deploy = n_deploy + 1
    end
  end
  expect.equality(n_deploy, 1) -- deduped: not listed twice
  local by_label = {}
  for _, i in ipairs(items) do
    by_label[i.label] = i
  end
  expect.equality(by_label["/ship"].kind, "command")
  expect.equality(by_label["/ship"].detail, "From config")
end

-- The CLI-resolved set is the only place a plugin-contributed command shows up, and it outranks
-- the static built-ins so a real command's own description wins over a hard-coded one.
T["items"]["slash trigger includes session.cli_commands, which outrank extra_commands"] = function()
  local sources = require "agentcomplete.sources"
  local session = fixture_session()
  session.cli_commands = {
    { name = "jira-create-child", description = "From the CLI" },
    { name = "init", description = "The user's own init" },
  }
  session.extra_commands = { { name = "init", description = "Static built-in init" } }
  local items = sources.items(session, { trigger = "/", query = "", start_col = 1 })
  local by_label = {}
  for _, i in ipairs(items) do
    by_label[i.label] = i
  end
  expect.equality(by_label["/jira-create-child"].kind, "command")
  expect.equality(by_label["/jira-create-child"].detail, "From the CLI")
  expect.equality(by_label["/init"].detail, "The user's own init")
end

-- A `hidden` static built-in must stay filtered even with a CLI set present: the CLI list is
-- consulted first, so a bug there would let the hidden flag be skipped rather than applied.
T["items"]["a hidden extra_command stays filtered when cli_commands are present"] = function()
  local sources = require "agentcomplete.sources"
  local session = fixture_session()
  session.cli_commands = { { name = "shown", description = "From the CLI" } }
  session.extra_commands = { { name = "themes", description = "TUI only", hidden = true } }
  local labels = vim.tbl_map(function(i)
    return i.label
  end, sources.items(session, { trigger = "/", query = "", start_col = 1 }))
  expect.equality(vim.tbl_contains(labels, "/shown"), true)
  expect.equality(vim.tbl_contains(labels, "/themes"), false)
end

T["items"]["slash trigger merges session.extra_skills, deduped by name against filesystem skills"] = function()
  local sources = require "agentcomplete.sources"
  local session = fixture_session()
  -- "deploy-helper" also exists on disk (fixture); "from-cli" is CLI-only.
  session.extra_skills = {
    { name = "from-cli", description = "Resolved via opencode debug skill" },
    { name = "deploy-helper", description = "CLI dup of the filesystem skill" },
  }
  local items = sources.items(session, { trigger = "/", query = "", start_col = 1 })
  local labels = vim.tbl_map(function(i)
    return i.label
  end, items)
  expect.equality(vim.tbl_contains(labels, "/from-cli"), true)
  local n_helper = 0
  for _, l in ipairs(labels) do
    if l == "/deploy-helper" then
      n_helper = n_helper + 1
    end
  end
  expect.equality(n_helper, 1) -- deduped: not listed twice
  local by_label = {}
  for _, i in ipairs(items) do
    by_label[i.label] = i
  end
  expect.equality(by_label["/from-cli"].kind, "skill")
  expect.equality(by_label["/from-cli"].detail, "Resolved via opencode debug skill")
  -- filesystem-first wins the dedup: detail comes from the on-disk skill
  expect.equality(by_label["/deploy-helper"].detail, "Helps deploy")
end

T["items"]["namespaces a plugin-sourced skill in label + insert_text; user skill stays bare"] = function()
  local sources = require "agentcomplete.sources"
  local root = tmpdir()
  write(root .. "/plug/skills/browsing/SKILL.md", { "---", "name: browsing", "description: browse", "---" })
  write(root .. "/user/skills/deploy/SKILL.md", { "---", "name: deploy", "description: deploy", "---" })
  local plugin_skills = root .. "/plug/skills"
  local user_skills = root .. "/user/skills"
  local session = {
    tool = "claude-code",
    cwd = root,
    skill_dirs = { plugin_skills, user_skills },
    command_dirs = {},
    skill_namespaces = { [plugin_skills] = "superplug" },
  }
  local by = {}
  for _, i in ipairs(sources.items(session, { trigger = "/", query = "", start_col = 1 })) do
    by[i.label] = i
  end
  -- plugin skill: both the displayed label and the inserted text carry the namespace
  expect.equality(by["/superplug:browsing"] ~= nil, true)
  expect.equality(by["/superplug:browsing"].insert_text, "superplug:browsing")
  expect.equality(by["/superplug:browsing"].kind, "skill")
  -- user/project skill (no namespace): stays unqualified
  expect.equality(by["/deploy"] ~= nil, true)
  expect.equality(by["/deploy"].insert_text, "deploy")
end

T["items"]["at trigger returns files under cwd matching the query"] = function()
  local sources = require "agentcomplete.sources"
  local session = fixture_session()
  local items = sources.items(session, { trigger = "@", query = "src/m", start_col = 1 })
  expect.equality(#items, 1)
  expect.equality(items[1].label, "@src/main.lua")
  expect.equality(items[1].insert_text, "src/main.lua")
  expect.equality(items[1].kind, "file")
end

T["items"]["nil context yields no items"] = function()
  local sources = require "agentcomplete.sources"
  expect.equality(sources.items(fixture_session(), nil), {})
end

T["items"]["honors session.sources toggles"] = function()
  local sources = require "agentcomplete.sources"
  local session = fixture_session()

  session.sources = { slash = true, file = false }
  expect.equality(sources.items(session, { trigger = "@", query = "", start_col = 1 }), {})

  session.sources = { slash = false, file = true }
  expect.equality(sources.items(session, { trigger = "/", query = "", start_col = 1 }), {})
end

T["items"]["excludes hidden built-in commands by default"] = function()
  local sources = require "agentcomplete.sources"
  local scan = require "agentcomplete.scan"
  local session = fixture_session()
  session.extra_commands = scan.opencode_builtin_commands()
  local labels = vim.tbl_map(function(i)
    return i.label
  end, sources.items(session, { trigger = "/", query = "", start_col = 1 }))
  expect.equality(vim.tbl_contains(labels, "/init"), true) -- shown: a conversation/session action
  expect.equality(vim.tbl_contains(labels, "/help"), false) -- hidden: opens a dialog
  expect.equality(vim.tbl_contains(labels, "/editor"), false) -- hidden: you are already in the editor
end

T["items"]["includes hidden built-ins when session.show_all_builtin_commands is set"] = function()
  local sources = require "agentcomplete.sources"
  local scan = require "agentcomplete.scan"
  local session = fixture_session()
  session.extra_commands = scan.opencode_builtin_commands()
  session.show_all_builtin_commands = true
  local labels = vim.tbl_map(function(i)
    return i.label
  end, sources.items(session, { trigger = "/", query = "", start_col = 1 }))
  expect.equality(vim.tbl_contains(labels, "/help"), true)
  expect.equality(vim.tbl_contains(labels, "/editor"), true)
end

T["items"]["a user command overrides a hidden built-in of the same name"] = function()
  local sources = require "agentcomplete.sources"
  local scan = require "agentcomplete.scan"
  local session = fixture_session()
  -- user-defined "help" ordered before the hidden built-in, mirroring how the detector merges them
  session.extra_commands = { { name = "help", description = "my help" } }
  vim.list_extend(session.extra_commands, scan.opencode_builtin_commands())
  local by = {}
  for _, i in ipairs(sources.items(session, { trigger = "/", query = "help", start_col = 1 })) do
    by[i.label] = i
  end
  expect.equality(by["/help"] ~= nil, true) -- shown because the user defined it (not hidden)
  expect.equality(by["/help"].detail, "my help")
end

return T
