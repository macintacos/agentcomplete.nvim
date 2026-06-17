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

return T
