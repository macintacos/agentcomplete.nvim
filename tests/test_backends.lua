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
  write(root .. "/src/lib/util.lua", { "" })
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

local function file_labels(items)
  local labels = {}
  for _, i in ipairs(items) do
    if i.kind == CIK.File then
      table.insert(labels, i.label)
    end
  end
  table.sort(labels)
  return labels
end

T["blink"]["@ items are narrowed to the whole typed run, past any /"] = function()
  local blink = require "agentcomplete.backends.blink"
  -- blink's own needle stops at "/", so it cannot narrow "src/li" itself.
  expect.equality(file_labels(blink.build(fixture_session(), "@src/li", 0, 7).items), { "@src/lib/util.lua" })
end

T["blink"]["@ alone is not swallowed by the empty-query matchfuzzy"] = function()
  local blink = require "agentcomplete.backends.blink"
  local session = fixture_session()
  expect.equality(file_labels(blink.build(session, "@", 0, 1).items), {
    "@commands/deploy.md",
    "@skills/deploy-helper/SKILL.md",
    "@skills/zebra/SKILL.md",
    "@src/lib/util.lua",
    "@src/main.lua",
  })
end

T["blink"]["@ narrowing is fuzzy, not a prefix filter"] = function()
  local blink = require "agentcomplete.backends.blink"
  expect.equality(file_labels(blink.build(fixture_session(), "@lib/ut", 0, 7).items), { "@src/lib/util.lua" })
end

T["blink"]["@ narrowing is case-insensitive"] = function()
  local blink = require "agentcomplete.backends.blink"
  expect.equality(file_labels(blink.build(fixture_session(), "@SRC/LI", 0, 7).items), { "@src/lib/util.lua" })
end

T["blink"]["deleting back past a / widens the list again"] = function()
  local blink = require "agentcomplete.backends.blink"
  local session = fixture_session()
  expect.equality(file_labels(blink.build(session, "@src/li", 0, 7).items), { "@src/lib/util.lua" })
  -- No narrowing is cached: the shorter run sees both src files again.
  expect.equality(file_labels(blink.build(session, "@src", 0, 4).items), { "@src/lib/util.lua", "@src/main.lua" })
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

-- Suppression: pure decision functions (constrain, resolve_sources) and the
-- install/uninstall glue that wraps blink's source lists. The glue is tested
-- against an injected fake blink config; package.loaded is reset per case so
-- module-level state (_detected stub, _installed) never leaks between tests.
T["suppress"] = new_set {
  hooks = {
    post_case = function()
      package.loaded["agentcomplete.backends.blink"] = nil
    end,
  },
}

T["suppress"]["constrain: empty allowed yields just agentcomplete"] = function()
  local blink = require "agentcomplete.backends.blink"
  local effective, dropped = blink.constrain({}, { agentcomplete = true, path = true })
  expect.equality(effective, { "agentcomplete" })
  expect.equality(dropped, {})
end

T["suppress"]["constrain: registered allowed kept in order, unregistered dropped"] = function()
  local blink = require "agentcomplete.backends.blink"
  local effective, dropped = blink.constrain(
    { "path", "ghost", "lsp" },
    { agentcomplete = true, path = true, lsp = true }
  )
  expect.equality(effective, { "agentcomplete", "path", "lsp" })
  expect.equality(dropped, { "ghost" })
end

T["suppress"]["constrain: agentcomplete is never duplicated"] = function()
  local blink = require "agentcomplete.backends.blink"
  local effective = blink.constrain({ "agentcomplete", "path" }, { agentcomplete = true, path = true })
  expect.equality(effective, { "agentcomplete", "path" })
end

T["suppress"]["resolve_sources: detected returns the constrained list, ignoring the original"] = function()
  local blink = require "agentcomplete.backends.blink"
  local effective = { "agentcomplete", "path" }
  expect.equality(blink.resolve_sources({ "lsp", "buffer" }, effective, true), effective)
  expect.equality(
    blink.resolve_sources(function()
      return { "lsp" }
    end, effective, true),
    effective
  )
end

T["suppress"]["resolve_sources: not detected passes a list original through unchanged"] = function()
  local blink = require "agentcomplete.backends.blink"
  expect.equality(blink.resolve_sources({ "lsp", "buffer" }, { "agentcomplete" }, false), { "lsp", "buffer" })
end

T["suppress"]["resolve_sources: not detected evaluates a function original"] = function()
  local blink = require "agentcomplete.backends.blink"
  local called = false
  local original = function()
    called = true
    return { "lsp", "snippets" }
  end
  expect.equality(blink.resolve_sources(original, { "agentcomplete" }, false), { "lsp", "snippets" })
  expect.equality(called, true)
end

T["suppress"]["install gates default + per_filetype on detection; uninstall restores"] = function()
  local blink = require "agentcomplete.backends.blink"
  local fake = {
    sources = {
      providers = { agentcomplete = true, path = true },
      default = { "lsp", "path", "buffer" },
      per_filetype = { markdown = { "lsp", "buffer" } },
    },
  }
  local detected = false
  expect.equality(
    blink.install_suppression({ allowed_sources = { "path" } }, fake, function()
      return detected
    end),
    true
  )
  -- Detected: only agentcomplete + allowed, beating BOTH default and per_filetype.markdown.
  detected = true
  expect.equality(fake.sources.default(), { "agentcomplete", "path" })
  expect.equality(fake.sources.per_filetype.markdown(), { "agentcomplete", "path" })
  -- Not detected: the user's original lists pass through untouched.
  detected = false
  expect.equality(fake.sources.default(), { "lsp", "path", "buffer" })
  expect.equality(fake.sources.per_filetype.markdown(), { "lsp", "buffer" })
  -- Uninstall restores the exact original values (not wrapped functions).
  blink.uninstall_suppression(fake)
  expect.equality(fake.sources.default, { "lsp", "path", "buffer" })
  expect.equality(fake.sources.per_filetype.markdown, { "lsp", "buffer" })
end

T["suppress"]["install is idempotent: re-install re-captures pristine originals"] = function()
  local blink = require "agentcomplete.backends.blink"
  local fake = {
    sources = {
      providers = { agentcomplete = true, path = true, lsp = true },
      default = { "lsp", "path" },
      per_filetype = {},
    },
  }
  local detected = false
  local pred = function()
    return detected
  end
  blink.install_suppression({ allowed_sources = { "path" } }, fake, pred)
  blink.install_suppression({ allowed_sources = { "lsp" } }, fake, pred) -- second setup, different allowed
  detected = true
  expect.equality(fake.sources.default(), { "agentcomplete", "lsp" })
  detected = false
  expect.equality(fake.sources.default(), { "lsp", "path" }) -- pristine original, not double-wrapped
end

T["suppress"]["unregistered allowed_sources are dropped and warned once at WARN"] = function()
  local blink = require "agentcomplete.backends.blink"
  local fake =
    { sources = { providers = { agentcomplete = true, path = true }, default = { "lsp" }, per_filetype = {} } }
  local notes = {}
  local orig_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level)
    table.insert(notes, { msg = msg, level = level })
  end
  local ok = blink.install_suppression({ allowed_sources = { "path", "ghost", "phantom" } }, fake, function()
    return true
  end)
  vim.notify = orig_notify
  expect.equality(ok, true)
  expect.equality(fake.sources.default(), { "agentcomplete", "path" }) -- ghost/phantom dropped
  expect.equality(#notes, 1)
  expect.equality(notes[1].level, vim.log.levels.WARN)
  expect.equality(notes[1].msg:find("ghost", 1, true) ~= nil, true)
  expect.equality(notes[1].msg:find("phantom", 1, true) ~= nil, true)
end

T["suppress"]["agentcomplete not registered: returns false, leaves config untouched, warns"] = function()
  local blink = require "agentcomplete.backends.blink"
  local original_default = { "lsp", "path" }
  local fake = { sources = { providers = { path = true }, default = original_default, per_filetype = {} } }
  local notes = {}
  local orig_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg, level)
    table.insert(notes, { msg = msg, level = level })
  end
  local ok = blink.install_suppression({ allowed_sources = {} }, fake)
  vim.notify = orig_notify
  expect.equality(ok, false)
  expect.equality(fake.sources.default, original_default) -- unchanged: still the raw list, not a function
  expect.equality(#notes >= 1, true)
  expect.equality(notes[1].level, vim.log.levels.WARN)
end

T["suppress"]["install_suppression is a no-op (false) when blink is absent"] = function()
  local blink = require "agentcomplete.backends.blink"
  expect.equality(blink.install_suppression { allowed_sources = {} }, false) -- no injected bcfg, blink not installed
end

T["suppress"]["dispatcher: false when blink is not the active backend"] = function()
  local backends = require "agentcomplete.backends"
  expect.equality(backends.install_suppression { backend = "native" }, false)
end

T["suppress"]["dispatcher: backend=blink but blink absent returns false without error"] = function()
  local backends = require "agentcomplete.backends"
  expect.equality(backends.install_suppression { backend = "blink", allowed_sources = {} }, false)
end

return T
