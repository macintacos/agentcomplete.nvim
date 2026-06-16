-- Tests for agentcomplete.backends: selection, the native mapping (prefix
-- filtered, vim complete-items) and the blink mapping (unfiltered, LSP items
-- with an explicit textEdit range), plus native attach/detach wiring.
local MiniTest = require "mini.test"
local new_set = MiniTest.new_set
local expect = MiniTest.expect

local CIK = vim.lsp.protocol.CompletionItemKind

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

local function write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

local function fixture_session()
  local root = tmpdir()
  write(root .. "/skills/deploy-helper/SKILL.md", { "---", "name: deploy-helper", "description: Helps deploy", "---" })
  write(root .. "/skills/zebra/SKILL.md", { "---", "name: zebra", "description: Stripes", "---" })
  write(root .. "/commands/deploy.md", { "---", "description: Deploy it", "---" })
  write(root .. "/src/main.lua", { "" })
  return {
    tool = "claude-code",
    cwd = root,
    skill_dirs = { root .. "/skills" },
    command_dirs = { root .. "/commands" },
  }
end

local function find(items, pred)
  for _, i in ipairs(items) do
    if pred(i) then
      return i
    end
  end
end

local T = new_set()

T["select"] = new_set()

T["select"]["auto resolves to native when blink is absent"] = function()
  local backends = require "agentcomplete.backends"
  expect.equality(backends.select { backend = "auto" }, "native")
end

T["select"]["explicit backends are honored"] = function()
  local backends = require "agentcomplete.backends"
  expect.equality(backends.select { backend = "native" }, "native")
  expect.equality(backends.select { backend = "blink" }, "blink")
end

T["native"] = new_set()

T["native"]["completions are prefix-filtered and mapped to vim complete-items"] = function()
  local native = require "agentcomplete.backends.native"
  local res = assert(native.completions(fixture_session(), "/dep", 4))
  expect.equality(res.start_col, 1) -- 0-based query start
  local words = vim.tbl_map(function(i)
    return i.word
  end, res.items)
  table.sort(words)
  expect.equality(words, { "deploy", "deploy-helper" }) -- "zebra" filtered out
  local deploy = assert(find(res.items, function(i)
    return i.word == "deploy"
  end))
  expect.equality(deploy.abbr, "/deploy")
  expect.equality(deploy.menu, "Deploy it")
end

T["native"]["no context yields no completions"] = function()
  local native = require "agentcomplete.backends.native"
  expect.equality(native.completions(fixture_session(), "hello", 5), nil)
end

T["blink"] = new_set()

T["blink"]["build returns UNFILTERED items with an explicit textEdit range"] = function()
  local blink = require "agentcomplete.backends.blink"
  local res = blink.build(fixture_session(), "/dep", 0, 4)
  local labels = vim.tbl_map(function(i)
    return i.label
  end, res.items)
  table.sort(labels)
  -- "zebra" is present even though "dep" wouldn't match it — blink does the filtering, not us.
  expect.equality(labels, { "/deploy", "/deploy-helper", "/zebra" })

  local deploy = assert(find(res.items, function(i)
    return i.label == "/deploy"
  end))
  expect.equality(deploy.filterText, "deploy")
  expect.equality(deploy.kind, CIK.Keyword)
  expect.equality(deploy.textEdit.newText, "deploy")
  expect.equality(deploy.textEdit.range.start.line, 0)
  expect.equality(deploy.textEdit.range.start.character, 1)
  expect.equality(deploy.textEdit.range["end"].character, 4)
end

T["blink"]["file items use the File kind"] = function()
  local blink = require "agentcomplete.backends.blink"
  local res = blink.build(fixture_session(), "@src", 0, 4)
  local f = assert(find(res.items, function(i)
    return i.label == "@src/main.lua"
  end))
  expect.equality(f.kind, CIK.File)
  expect.equality(f.textEdit.newText, "src/main.lua")
end

T["blink"]["no context yields no items"] = function()
  local blink = require "agentcomplete.backends.blink"
  expect.equality(blink.build(fixture_session(), "hello", 0, 5).items, {})
end

T["attach"] = new_set()

T["attach"]["native attach sets a buffer-local completefunc; detach clears it"] = function()
  local backends = require "agentcomplete.backends"
  local buf = vim.api.nvim_create_buf(false, true)
  backends.attach(buf, fixture_session(), { backend = "native", sources = { slash = true, file = true } })
  expect.equality(vim.bo[buf].completefunc ~= "", true)
  backends.detach(buf)
  expect.equality(vim.bo[buf].completefunc, "")
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T
