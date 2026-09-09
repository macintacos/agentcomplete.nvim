-- Tests for agentcomplete.context: the resolver registry, the Claude Code transcript resolver,
-- the OpenCode database resolver, and the pane built around them. Roots, subprocesses and the
-- clock are injected, so no real `$HOME`, `ps`, formatter or OpenCode database is touched --
-- except the fixture database the OpenCode query is deliberately run against.
local MiniTest = require "mini.test"
local new_set = MiniTest.new_set
local expect = MiniTest.expect

local SID = "11111111-2222-3333-4444-555555555555"

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

local function text_block(s)
  return { type = "text", text = s }
end

local function tool_block(name)
  return { type = "tool_use", id = "t1", name = name, input = vim.empty_dict() }
end

---One transcript line. `extra` overrides the entry's top-level fields (`isSidechain`, …).
local function assistant(blocks, extra)
  local entry = { type = "assistant", sessionId = SID, message = { content = blocks } }
  return vim.json.encode(vim.tbl_extend("force", entry, extra or {}))
end

---A sessions/projects root pair: `sessions/<pid>.json` pointing at a transcript holding `lines`.
---@param lines string[]
---@param pid? integer Owner pid of the session file; defaults to this process's parent.
local function fixture(lines, pid)
  local root = tmpdir()
  pid = pid or vim.loop.os_getppid()
  local transcript = root .. "/projects/proj/" .. SID .. ".jsonl"
  vim.fn.mkdir(root .. "/sessions", "p")
  vim.fn.mkdir(root .. "/projects/proj", "p")
  vim.fn.writefile(
    { vim.json.encode { pid = pid, sessionId = SID, cwd = "/proj" } },
    root .. "/sessions/" .. pid .. ".json"
  )
  vim.fn.writefile(lines, transcript)
  return { sessions_root = root .. "/sessions", projects_root = root .. "/projects", transcript = transcript }
end

---A session shaped like the registry's contract, for cases where the tool is all that matters.
local function session_for(tool)
  return { tool = tool, cwd = "/proj", skill_dirs = {}, command_dirs = {} }
end

---Run the resolver against `opts` and return the result it reported plus whether it claimed.
local function resolve(opts, session)
  local result
  local claimed = require("agentcomplete.context.claude_code").resolve(session or session_for "claude-code", function(r)
    result = r
  end, opts)
  return result, claimed
end

local T = new_set {
  hooks = {
    pre_case = function()
      require("agentcomplete.context").clear()
    end,
  },
}

T["registry"] = new_set()

---A resolver that claims every session and reports `result`.
local function stub(name, result)
  return {
    name = name,
    resolve = function(_, cb)
      cb(result)
      return true
    end,
  }
end

T["registry"]["the first resolver to claim wins"] = function()
  local context = require "agentcomplete.context"
  context.register(stub("first", { ok = true, resolver = "first", text = "a" }))
  context.register(stub("second", { ok = true, resolver = "second", text = "b" }))
  local seen
  local claimed = context.resolve(session_for "any", function(r)
    seen = r
  end)
  expect.equality(claimed, "first")
  expect.equality(seen.text, "a")
end

T["registry"]["a resolver that declines hands the session to the next"] = function()
  local context = require "agentcomplete.context"
  context.register { name = "declines", resolve = function() end }
  context.register(stub("claims", { ok = true, resolver = "claims", text = "b" }))
  local seen
  expect.equality(
    context.resolve(session_for "any", function(r)
      seen = r
    end),
    "claims"
  )
  expect.equality(seen.text, "b")
end

T["registry"]["a resolver that throws is skipped rather than aborting the walk"] = function()
  local context = require "agentcomplete.context"
  context.register {
    name = "raises",
    resolve = function()
      error "boom"
    end,
  }
  context.register(stub("claims", { ok = true, resolver = "claims", text = "b" }))
  expect.equality(context.resolve(session_for "any", function() end), "claims")
end

-- "no resolver is registered" and "the registered one crashed" are opposite problems, and the
-- failure log is where a maintainer tells them apart.
T["registry"]["carries out the error when a raising resolver is the only candidate"] = function()
  local context = require "agentcomplete.context"
  context.register {
    name = "raises",
    resolve = function()
      error "transcript decode blew up"
    end,
  }
  local claimed, err = context.resolve(session_for "any", function() end)
  expect.equality(claimed, nil)
  err = assert(err, "no error carried out")
  expect.equality(err:find("raises", 1, true) ~= nil, true)
  expect.equality(err:find("transcript decode blew up", 1, true) ~= nil, true)
end

T["registry"]["passes resolver seams through to the resolver"] = function()
  local context = require "agentcomplete.context"
  local seen
  context.register {
    name = "records",
    resolve = function(_, _, opts)
      seen = opts
      return true
    end,
  }
  context.resolve(session_for "any", function() end, { sessions_root = "/fixture" })
  expect.equality(seen.sessions_root, "/fixture")
end

T["registry"]["reports nothing when no resolver claims the session"] = function()
  local context = require "agentcomplete.context"
  context.register { name = "declines", resolve = function() end }
  local called = false
  expect.equality(
    context.resolve(session_for "any", function()
      called = true
    end),
    nil
  )
  expect.equality(called, false)
end

T["claude_code.resolve"] = new_set()

T["claude_code.resolve"]["reports the newest assistant text, past later tool-only turns"] = function()
  local result = resolve(fixture {
    assistant { text_block "older" },
    assistant { text_block "the answer" },
    assistant { tool_block "Bash" },
    assistant { tool_block "Read" },
  })
  expect.equality(result.ok, true)
  expect.equality(result.text, "the answer")
end

T["claude_code.resolve"]["skips sidechain entries"] = function()
  local result = resolve(fixture {
    assistant { text_block "main thread" },
    assistant({ text_block "subagent chatter" }, { isSidechain = true }),
  })
  expect.equality(result.text, "main thread")
end

T["claude_code.resolve"]["concatenates every text block in the entry"] = function()
  local result = resolve(fixture { assistant { text_block "first", tool_block "Bash", text_block "second" } })
  expect.equality(result.text, "first\n\nsecond")
end

-- `tool_result` payloads routinely embed transcript-shaped JSON as a string, so a line that
-- fails to decode (or decodes to something unexpected) must not abort the backward walk.
T["claude_code.resolve"]["an undecodable line does not abort the scan"] = function()
  local result = resolve(fixture {
    assistant { text_block "the answer" },
    '{"type":"assistant","message":{"content":[{"type":"text","text":"trunc',
  })
  expect.equality(result.text, "the answer")
end

-- A real transcript's final turns are tool calls, so the newest text block can sit hundreds of
-- kilobytes back: the tail has to grow past its initial chunk rather than give up at it.
T["claude_code.resolve"]["finds a message beyond the first tail chunk"] = function()
  local lines = { assistant { text_block "deep answer" } }
  local pad = string.rep("x", 50000)
  for _ = 1, 8 do
    lines[#lines + 1] = assistant { { type = "tool_use", id = "t1", name = "Bash", input = { command = pad } } }
  end
  local result = resolve(fixture(lines))
  expect.equality(result.ok, true)
  expect.equality(result.text, "deep answer")
end

T["claude_code.resolve"]["walks up to the session file through a ps hop"] = function()
  local orphan = vim.loop.os_getppid() + 1000000
  local fx = fixture({ assistant { text_block "found via hop" } }, orphan)
  local asked = {}
  local result = resolve {
    sessions_root = fx.sessions_root,
    projects_root = fx.projects_root,
    system = function(cmd)
      asked[#asked + 1] = cmd
      return "  " .. orphan .. "\n"
    end,
  }
  expect.equality(result.text, "found via hop")
  expect.equality(#asked, 1)
end

T["claude_code.resolve"]["reports the session id and transcript it resolved"] = function()
  local fx = fixture { assistant { text_block "hi" } }
  local result = resolve { sessions_root = fx.sessions_root, projects_root = fx.projects_root }
  expect.equality(result.session_id, SID)
  expect.equality(result.transcript, fx.transcript)
end

T["claude_code.resolve"]["fills the session's id, which detection leaves nil"] = function()
  local fx = fixture { assistant { text_block "hi" } }
  local session = session_for "claude-code"
  resolve({ sessions_root = fx.sessions_root, projects_root = fx.projects_root }, session)
  expect.equality(session.session_id, SID)
end

T["claude_code.resolve"]["fails soft when no session file is found"] = function()
  local result = resolve {
    sessions_root = tmpdir(),
    projects_root = tmpdir(),
    system = function()
      return ""
    end,
  }
  expect.equality(result.ok, false)
  expect.equality(type(result.err), "string")
end

T["claude_code.resolve"]["fails soft when the transcript is missing"] = function()
  local fx = fixture { assistant { text_block "hi" } }
  vim.fn.delete(fx.transcript)
  local result = resolve { sessions_root = fx.sessions_root, projects_root = fx.projects_root }
  expect.equality(result.ok, false)
  expect.equality(type(result.err), "string")
end

T["claude_code.resolve"]["fails soft when the transcript holds no assistant text"] = function()
  local fx = fixture { assistant { tool_block "Bash" } }
  local result = resolve { sessions_root = fx.sessions_root, projects_root = fx.projects_root }
  expect.equality(result.ok, false)
  expect.equality(type(result.err), "string")
end

-- Every resolver sees every session, so declining one that isn't its tool is what lets the
-- registry keep walking to the one that owns it.
T["claude_code.resolve"]["declines a session belonging to another tool"] = function()
  local fx = fixture { assistant { text_block "hi" } }
  local result, claimed =
    resolve({ sessions_root = fx.sessions_root, projects_root = fx.projects_root }, session_for "opencode")
  expect.equality(claimed, nil)
  expect.equality(result, nil)
end

T["format"] = new_set()

---A `vim.system` stand-in whose process exits `code` with `stdout`.
local function fake_system(code, stdout)
  return function()
    return {
      wait = function()
        return { code = code, stdout = stdout }
      end,
    }
  end
end

T["format"]["returns the formatter's output"] = function()
  local context = require "agentcomplete.context"
  expect.equality(context.format("*  a\n", fake_system(0, "- a\n")), "- a\n")
end

T["format"]["falls back to the raw text when the formatter fails"] = function()
  local context = require "agentcomplete.context"
  expect.equality(context.format("*  a\n", fake_system(1, "")), "*  a\n")
end

T["format"]["falls back to the raw text when the formatter is absent"] = function()
  local context = require "agentcomplete.context"
  expect.equality(
    context.format("*  a\n", function()
      error "ENOENT"
    end),
    "*  a\n"
  )
end

-- Unbounded, this waits on the main loop as the prompt buffer opens, so a hung formatter
-- would freeze the editor rather than cost the pane.
T["format"]["falls back to the raw text when the formatter outruns its timeout"] = function()
  local context = require "agentcomplete.context"
  local waited
  local system = function()
    return {
      wait = function(_, timeout)
        waited = timeout
        return nil
      end,
    }
  end
  expect.equality(context.format("*  a\n", system), "*  a\n")
  expect.equality(type(waited), "number")
end

T["log"] = new_set()

T["log"]["appends one timestamped line per call"] = function()
  local context = require "agentcomplete.context"
  local path = tmpdir() .. "/context.log"
  context.log(path, "first", "T1")
  context.log(path, "second", "T2")
  expect.equality(vim.fn.readfile(path), { "[T1] first", "[T2] second" })
end

-- `vim.fn.mkdir` throws when the directory cannot be made, and both the module docstring and
-- the vimdoc promise this path raises nothing.
T["log"]["does not raise when the directory cannot be created"] = function()
  local context = require "agentcomplete.context"
  local blocker = tmpdir() .. "/blocker"
  vim.fn.writefile({ "" }, blocker)
  expect.equality(pcall(context.log, blocker .. "/context.log", "boom", "T1"), true)
end

T["open"] = new_set {
  hooks = {
    pre_case = function()
      vim.cmd "silent! only"
    end,
    post_case = function()
      local context = require "agentcomplete.context"
      for buf in pairs(context._state) do
        context.close(buf)
      end
      vim.cmd "silent! only"
      vim.o.columns = 80
    end,
  },
}

---A prompt buffer holding `lines`, focused.
---@param lines? string[]
local function prompt_buffer(lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "" })
  vim.api.nvim_set_current_buf(buf)
  return buf
end

---Register a resolver reporting `result`, and return an `open` opts table with a temp log.
---`format` is stubbed to the identity so the pane cases never spawn the real formatter — what
---they assert is the pane, not `rumdl`'s output.
local function with_resolver(result)
  require("agentcomplete.context").register(stub(result.resolver, result))
  return {
    headless = false,
    log_path = tmpdir() .. "/context.log",
    format = function(text)
      return text
    end,
  }
end

local function ok_result(text)
  return { ok = true, resolver = "claude-code", text = text, session_id = SID, transcript = "/t.jsonl" }
end

---The window holding the message: the floating one. `open` leaves two windows behind — the
---split that reserves the room and the float that fills it — so "not the prompt's" no longer
---picks one out.
local function pane_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      return win
    end
  end
end

---The text of a float's title, with its highlight groups dropped.
local function title_text(win)
  return table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, vim.api.nvim_win_get_config(win).title))
end

---The split the float sits over, i.e. the remaining non-floating window that is not `prompt_win`.
local function spacer_win(prompt_win)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= prompt_win and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
end

T["open"]["splits vertically when the terminal is at least min_width wide"] = function()
  local context = require "agentcomplete.context"
  vim.o.columns = 200
  local buf = prompt_buffer()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  expect.equality(vim.fn.winlayout()[1], "row")
end

T["open"]["splits horizontally when the terminal is narrower than min_width"] = function()
  local context = require "agentcomplete.context"
  vim.o.columns = 80
  local buf = prompt_buffer()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  expect.equality(vim.fn.winlayout()[1], "col")
end

T["open"]["leaves the pane read-only and the cursor in the prompt"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  local prompt_win = vim.api.nvim_get_current_win()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  local win = assert(pane_win())
  expect.equality(vim.bo[vim.api.nvim_win_get_buf(win)].modifiable, false)
  expect.equality(vim.api.nvim_get_current_win(), prompt_win)
end

T["open"]["frames the message, naming the resolver in the border"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  local win = assert(pane_win())
  local config = vim.api.nvim_win_get_config(win)
  expect.equality(config.border[1], "╭")
  expect.equality(title_text(win), "─ claude-code · last message ")
  local footer = table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, config.footer))
  expect.equality(footer:find("read-only", 1, true) ~= nil, true)
end

-- The rung the resolver answered on is what admits a guessed session is a guess, so it belongs
-- where the reader already looks to see whose message this is.
T["open"]["names the resolution rung in the border"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  local result = { ok = true, resolver = "opencode", rung = "pointer file", text = "hello" }
  context.open(buf, session_for "opencode", { enabled = true, min_width = 160 }, with_resolver(result))
  expect.equality(title_text(assert(pane_win())), "─ opencode · pointer file · last message ")
end

-- The pane is the one markdown in the editor nobody will edit, so the markup that exists to
-- be edited is what it hides. Everything a gutter is for -- line numbers to jump to, signs,
-- folds -- addresses a buffer you act on, and this is a buffer you read.
T["open"]["reads as a document rather than an editable buffer"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  local win = assert(pane_win())
  expect.equality(vim.wo[win].number, false)
  expect.equality(vim.wo[win].relativenumber, false)
  expect.equality(vim.wo[win].signcolumn, "no")
  expect.equality(vim.wo[win].foldcolumn, "0")
  expect.equality(vim.wo[win].spell, false)
  expect.equality(vim.wo[win].conceallevel, 3)
  expect.equality(vim.wo[win].wrap, true)
  expect.equality(vim.bo[vim.api.nvim_win_get_buf(win)].filetype, "markdown")
end

-- Window-local options are set against whichever window is current, so a filetype set before
-- the pane has one lands on the prompt instead -- taking every ftplugin and FileType autocmd
-- with it, and leaving the pane itself unrendered.
-- A filetype set on a buffer no window is showing fires `FileType` inside a scratch
-- autocommand window, so every window-local option an ftplugin sets is applied there and
-- thrown away with it. The pane needs its window first or it renders as plain text: the
-- markdown plugins that would style it are exactly the ones setting those options.
T["open"]["gives the pane a window before its filetype, so ftplugins reach it"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  local grp = vim.api.nvim_create_augroup("AgentCompleteContextFtTest", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = grp,
    pattern = "markdown",
    callback = function()
      vim.opt_local.foldlevel = 7
    end,
  })
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  vim.api.nvim_del_augroup_by_id(grp)
  expect.equality(vim.wo[assert(pane_win())].foldlevel, 7)
end

T["open"]["shows the message from its first line"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(assert(pane_win())), 0, -1, false)
  expect.equality(lines[1], "hello")
end

-- The split exists only to reserve the room the float fills; landing in it means landing on an
-- empty buffer exactly where the message appears to be.
T["open"]["hands the cursor to the message when the split is entered"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  local prompt_win = vim.api.nvim_get_current_win()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  vim.api.nvim_set_current_win(assert(spacer_win(prompt_win)))
  vim.wait(100)
  expect.equality(vim.api.nvim_get_current_win(), pane_win())
end

-- Every window move that leaves the float lands on the split first -- `<C-w>h`, `<C-w>p` and
-- `<C-w>W` all do. Passing the cursor on to the message there, rather than back out, is what
-- makes the pane impossible to leave.
T["open"]["lets the cursor leave the message through the split"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  local prompt_win = vim.api.nvim_get_current_win()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  vim.api.nvim_set_current_win(assert(pane_win()))
  vim.api.nvim_set_current_win(assert(spacer_win(prompt_win)))
  vim.wait(100)
  expect.equality(vim.api.nvim_get_current_win(), prompt_win)
end

-- The reply being composed is the work; the message beside it is reference for that work.
T["open"]["leaves the prompt the greater share of the width"] = function()
  local context = require "agentcomplete.context"
  vim.o.columns = 200
  local buf = prompt_buffer()
  local prompt_win = vim.api.nvim_get_current_win()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  expect.equality(vim.api.nvim_win_get_width(assert(spacer_win(prompt_win))), 80)
end

-- The terminal is resized mid-session, and an orientation chosen once at open time leaves the
-- pane wedged beside a prompt with no room for either.
T["open"]["moves the pane below the prompt when the terminal narrows"] = function()
  local context = require "agentcomplete.context"
  vim.o.columns = 200
  local buf = prompt_buffer()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  expect.equality(vim.fn.winlayout()[1], "row")
  vim.o.columns = 80
  vim.api.nvim_exec_autocmds("VimResized", {})
  vim.wait(100)
  expect.equality(vim.fn.winlayout()[1], "col")
end

-- Quitting the prompt is how the agent CLI is answered, so both of the pane's windows have to
-- be gone *before* that quit resolves: either one still standing is a window Neovim keeps the
-- editor open for, leaving the reader in a message they cannot reply to instead of back at the
-- agent. Asserting the prompt window is still open is what pins the ordering — after it closes,
-- dismissing the pane is too late to matter.
T["open"]["dismisses the pane before the prompt's quit resolves"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  local prompt_win = vim.api.nvim_get_current_win()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  local win, spacer = assert(pane_win()), assert(spacer_win(prompt_win))
  vim.api.nvim_exec_autocmds("QuitPre", { buffer = buf })
  expect.equality(vim.api.nvim_win_is_valid(win), false)
  expect.equality(vim.api.nvim_win_is_valid(spacer), false)
  expect.equality(vim.api.nvim_win_is_valid(prompt_win), true)
end

T["open"]["closes the pane when the prompt buffer is wiped"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  local win = assert(pane_win())
  -- Deleting the prompt buffer closes its window; without a third one the pane would be the
  -- last window standing, which Neovim will not close.
  vim.cmd "botright new"
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.wait(500, function()
    return not vim.api.nvim_win_is_valid(win)
  end)
  expect.equality(vim.api.nvim_win_is_valid(win), false)
end

-- Claude Code's own `externalEditorContext` renders the conversation into the prompt buffer.
-- Opening beside it would show the same message twice.
T["open"]["skips a buffer Claude Code already rendered context into"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer { "prior turn", "# ─── Write your reply below this line ───", "" }
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  expect.equality(#vim.api.nvim_list_wins(), 1)
end

T["open"]["skips when the feature is disabled"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  context.open(buf, session_for "claude-code", { enabled = false, min_width = 160 }, with_resolver(ok_result "hello"))
  expect.equality(#vim.api.nvim_list_wins(), 1)
end

T["open"]["skips when there is no UI to split"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  local opts = with_resolver(ok_result "hello")
  opts.headless = true
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, opts)
  expect.equality(#vim.api.nvim_list_wins(), 1)
end

T["open"]["records what it resolved for the diagnostics report"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  local result = vim.tbl_extend("force", ok_result "hello", { rung = "guessed" })
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(result))
  expect.equality(context._state[buf].resolver, "claude-code")
  expect.equality(context._state[buf].rung, "guessed")
  expect.equality(context._state[buf].session_id, SID)
  expect.equality(context._state[buf].transcript, "/t.jsonl")
  expect.equality(context._state[buf].bytes, 5)
end

T["open"]["logs a resolver failure instead of opening a pane"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  local opts = with_resolver { ok = false, resolver = "claude-code", err = "no transcript" }
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, opts)
  expect.equality(#vim.api.nvim_list_wins(), 1)
  expect.equality(#vim.fn.readfile(opts.log_path), 1)
  expect.equality(context._state[buf].err, "no transcript")
end

-- A tool whose resolver has not shipped yet is normal operation, not a failure, and the log
-- lives in the user's own project — so this path must leave the filesystem alone.
T["open"]["records a tool no resolver claims without writing a log"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  local opts = { headless = false, log_path = tmpdir() .. "/context.log" }
  context.open(buf, session_for "some-other-agent", { enabled = true, min_width = 160 }, opts)
  expect.equality(#vim.api.nvim_list_wins(), 1)
  expect.equality(vim.fn.filereadable(opts.log_path), 0)
  expect.equality(type(context._state[buf].err), "string")
end

T["open"]["logs a resolver that raised, naming it"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  context.register {
    name = "explodes",
    resolve = function()
      error "transcript decode blew up"
    end,
  }
  local opts = { headless = false, log_path = tmpdir() .. "/context.log" }
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, opts)
  expect.equality(vim.fn.readfile(opts.log_path)[1]:find("transcript decode blew up", 1, true) ~= nil, true)
end

T["open"]["opens one pane however many times it is called"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  local opts = with_resolver(ok_result "hello")
  local config = { enabled = true, min_width = 160 }
  context.open(buf, session_for "claude-code", config, opts)
  context.open(buf, session_for "claude-code", config, opts)
  expect.equality(#vim.api.nvim_list_wins(), 3)
end

-- `:edit!` fires BufUnload but not BufDelete, and the buffer survives it — so must the pane.
T["open"]["keeps the pane across a reload of the prompt buffer"] = function()
  local context = require "agentcomplete.context"
  local path = tmpdir() .. "/claude-prompt-reload.md"
  vim.fn.writefile({ "draft" }, path)
  vim.cmd("silent edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  local win = assert(pane_win())
  vim.cmd "silent edit!"
  vim.wait(100)
  expect.equality(vim.api.nvim_win_is_valid(win), true)
end

T["open"]["releases per-buffer state when a failed buffer goes away"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  local opts = with_resolver { ok = false, resolver = "claude-code", err = "no transcript" }
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, opts)
  expect.equality(context._state[buf].err, "no transcript")
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.wait(500, function()
    return context._state[buf] == nil
  end)
  expect.equality(context._state[buf], nil)
end

-- The registry, the real resolver, and the pane are otherwise only tested apart; this is the
-- one case that drives all three together.
T["open"]["shows a message resolved by the real Claude Code resolver"] = function()
  local context = require "agentcomplete.context"
  context.register(require "agentcomplete.context.claude_code")
  local fx = fixture { assistant { text_block "resolved for real" } }
  local buf = prompt_buffer()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, {
    headless = false,
    log_path = tmpdir() .. "/context.log",
    format = function(text)
      return text
    end,
    resolver = { sessions_root = fx.sessions_root, projects_root = fx.projects_root },
  })
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(assert(pane_win())), 0, -1, false)
  expect.equality(vim.tbl_contains(lines, "resolved for real"), true)
  expect.equality(context._state[buf].session_id, SID)
  expect.equality(context._state[buf].transcript, fx.transcript)
end

-- The pane is two windows over two scratch buffers, and closing a window does not take its
-- buffer with it: unwiped, every prompt a session opens leaves one behind for its lifetime.
T["open"]["leaves no buffer behind when the pane closes"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  local before = #vim.api.nvim_list_bufs()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  context.close(buf)
  expect.equality(#vim.api.nvim_list_bufs(), before)
end

-- `_state` is what the diagnostics report reads to explain a missing pane, so "the message
-- resolved" and "the message is on screen" cannot be the same answer.
T["open"]["records a failure when the prompt buffer is on no screen to split from"] = function()
  local context = require "agentcomplete.context"
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hi"))
  expect.equality(type(context._state[buf].err), "string")
end

-- A resolver reports once. A second report would build a second pane over the first and
-- overwrite the record of the first one's windows, leaving two nothing can close.
T["open"]["ignores a resolver that reports twice"] = function()
  local context = require "agentcomplete.context"
  context.register {
    name = "twice",
    resolve = function(_, cb)
      cb(ok_result "first")
      cb(ok_result "second")
      return true
    end,
  }
  local buf = prompt_buffer()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, {
    headless = false,
    log_path = tmpdir() .. "/context.log",
    format = function(text)
      return text
    end,
  })
  expect.equality(#vim.api.nvim_list_wins(), 3)
end

-- Every window the pane owns is a way out of it, so the teardown listens on all of them: a
-- split closed on its own would otherwise leave the float drawn over nothing.
T["open"]["dismisses the pane when the split it sits over is closed"] = function()
  local context = require "agentcomplete.context"
  local buf = prompt_buffer()
  local prompt = vim.api.nvim_get_current_win()
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  local float = assert(pane_win())
  vim.api.nvim_win_close(assert(spacer_win(prompt)), true)
  expect.equality(vim.api.nvim_win_is_valid(float), false)
end

T["opencode.parse_etime"] = new_set()

-- `ps -o etime=` is POSIX `[[dd-]hh:]mm:ss`; macOS has no `etimes` to ask for seconds
-- directly, so the heuristic rung's floor rides on reading every one of those shapes.
T["opencode.parse_etime"]["reads every field width ps emits"] = function()
  local opencode = require "agentcomplete.context.opencode"
  expect.equality(opencode.parse_etime "03:15", 195)
  expect.equality(opencode.parse_etime "  01:02:03", 3723)
  expect.equality(opencode.parse_etime "2-01:02:03", 2 * 86400 + 3723)
end

T["opencode.parse_etime"]["returns nil for output that is not an elapsed time"] = function()
  local opencode = require "agentcomplete.context.opencode"
  expect.equality(opencode.parse_etime "", nil)
  expect.equality(opencode.parse_etime "ps: etime: keyword not found", nil)
end

T["opencode.pick_pointer"] = new_set()

---A pointer record as the OpenCode plugin writes it.
local function pointer(fields)
  return vim.tbl_extend("force", {
    pids = { 4242 },
    sessionID = "ses_a",
    directory = "/proj",
    worktree = "/proj",
    ts = 1000,
  }, fields or {})
end

T["opencode.pick_pointer"]["takes the record whose pids reach this process tree"] = function()
  local opencode = require "agentcomplete.context.opencode"
  local records = { pointer { pids = { 9 }, sessionID = "ses_elsewhere" }, pointer { pids = { 7, 4242 } } }
  expect.equality(opencode.pick_pointer(records, { 4242, 11 }, "/proj").sessionID, "ses_a")
end

-- A worktree checkout runs OpenCode from the worktree while the session records the main
-- checkout as its directory, so either side of that pair is a match.
T["opencode.pick_pointer"]["matches a cwd that is the record's worktree rather than its directory"] = function()
  local opencode = require "agentcomplete.context.opencode"
  local records = { pointer { directory = "/main", worktree = "/proj" } }
  expect.equality(opencode.pick_pointer(records, { 4242 }, "/proj").sessionID, "ses_a")
end

-- Pids are recycled, so a pid match alone would let a week-old record from an unrelated
-- project answer for this one.
T["opencode.pick_pointer"]["skips a record naming another directory"] = function()
  local opencode = require "agentcomplete.context.opencode"
  local records = { pointer { directory = "/elsewhere", worktree = "/elsewhere" } }
  expect.equality(opencode.pick_pointer(records, { 4242 }, "/proj"), nil)
end

T["opencode.pick_pointer"]["prefers the freshest of several matching records"] = function()
  local opencode = require "agentcomplete.context.opencode"
  local records = {
    pointer { sessionID = "ses_fresh", ts = 2000 },
    pointer { sessionID = "ses_stale", ts = 500 },
  }
  expect.equality(opencode.pick_pointer(records, { 4242 }, "/proj").sessionID, "ses_fresh")
end

T["opencode.pick_pointer"]["declines when no record names a pid in the chain"] = function()
  local opencode = require "agentcomplete.context.opencode"
  expect.equality(opencode.pick_pointer({ pointer() }, { 55, 56 }, "/proj"), nil)
end

local saved_opencode
T["opencode.resolve"] = new_set {
  hooks = {
    pre_case = function()
      saved_opencode = { session = vim.env.OPENCODE_SESSION_ID, pid = vim.env.OPENCODE_PID }
      vim.env.OPENCODE_SESSION_ID = nil
      vim.env.OPENCODE_PID = nil
    end,
    post_case = function()
      vim.env.OPENCODE_SESSION_ID = saved_opencode.session
      vim.env.OPENCODE_PID = saved_opencode.pid
    end,
  },
}

local function session_row(id, parent, directory, created)
  return ("insert into session values('%s',%s,'%s',%d);"):format(
    id,
    parent and ("'" .. parent .. "'") or "null",
    directory,
    created
  )
end

---An assistant turn: one `message` row, and one `part` row per `{ type, text }` pair.
local function turn(session, id, created, parts)
  local rows = {
    ("insert into message values('%s','%s',%d,'%s');"):format(
      id,
      session,
      created,
      vim.json.encode { role = "assistant" }
    ),
  }
  for i, part in ipairs(parts) do
    rows[#rows + 1] = ("insert into part values('%s.%d','%s','%s',%d,'%s');"):format(
      id,
      i,
      id,
      session,
      created + i,
      vim.json.encode { type = part[1], text = part[2] }
    )
  end
  return table.concat(rows, "\n")
end

---The OpenCode database the query is exercised against, in the column shapes OpenCode itself
---uses. `ses_new` is the newest root session in `/proj`; `ses_old` predates the heuristic's
---floor, `ses_child` is a subagent's, and `ses_other` belongs to another project. Read-only, so
---it is built once and shared.
local db_fixture
local function opencode_db()
  if db_fixture then
    return db_fixture
  end
  db_fixture = tmpdir() .. "/opencode.db"
  vim.fn.system(
    { "sqlite3", db_fixture },
    table.concat({
      "create table session(id text primary key, parent_id text, directory text, time_created integer);",
      "create table message(id text primary key, session_id text, time_created integer, data text);",
      "create table part(id text primary key, message_id text, session_id text, time_created integer, data text);",
      session_row("ses_old", nil, "/proj", 1000000),
      turn("ses_old", "m1", 1000100, { { "text", "old answer" } }),
      session_row("ses_new", nil, "/proj", 1800000),
      turn("ses_new", "m2", 1800100, { { "text", "superseded" } }),
      turn("ses_new", "m3", 1800200, { { "text", "the answer" }, { "text", "and more" } }),
      turn("ses_new", "m4", 1800300, { { "tool" } }),
      session_row("ses_child", "ses_new", "/proj", 1850000),
      turn("ses_child", "m5", 1850100, { { "text", "subagent chatter" } }),
      session_row("ses_other", nil, "/other", 1900000),
      turn("ses_other", "m6", 1900100, { { "text", "another project" } }),
    }, "\n")
  )
  return db_fixture
end

---Write `record` where the OpenCode plugin writes its pointers, under a fixture state root.
local function write_pointer(root, pid, record)
  vim.fn.mkdir(root .. "/opencode/agentcomplete", "p")
  vim.fn.writefile({ vim.json.encode(record) }, root .. "/opencode/agentcomplete/" .. pid .. ".json")
end

---A `ps` stand-in: an elapsed time for the heuristic's floor, and no parent for the pid climb,
---so no real process tree is read.
local function fake_ps(cmd)
  return cmd[3] == "etime=" and "05:00\n" or ""
end

---Seams placing the resolver's clock 300 seconds past `ses_new`, so the heuristic's floor
---(1700000) falls between `ses_old` and `ses_new`.
local function opencode_opts(fields)
  return vim.tbl_extend("force", {
    state_root = tmpdir(),
    db_path = opencode_db(),
    system = fake_ps,
    now = function()
      return 2000000
    end,
  }, fields or {})
end

---Run the OpenCode resolver against `opts`, waiting for its asynchronous report.
local function resolve_opencode(opts, session)
  local result
  local claimed = require("agentcomplete.context.opencode").resolve(session or session_for "opencode", function(r)
    result = r
  end, opts)
  if claimed then
    vim.wait(5000, function()
      return result ~= nil
    end)
  end
  return result, claimed
end

-- The parts of one message, not every assistant part in the session: a session's whole
-- conversation would otherwise land in the pane.
T["opencode.resolve"]["reads the newest assistant message that carries text"] = function()
  local opencode = require "agentcomplete.context.opencode"
  local out = vim.fn.system { "sqlite3", "-readonly", "-json", opencode_db(), opencode.message_sql "'ses_new'" }
  expect.equality(opencode.join_rows(out), "the answer\n\nand more")
end

T["opencode.resolve"]["reports nothing for output that is not a result set"] = function()
  local opencode = require "agentcomplete.context.opencode"
  expect.equality(opencode.join_rows "", nil)
  expect.equality(opencode.join_rows "[]", nil)
end

-- Nothing exports this today, but three lines in OpenCode's `openEditor` would, and it is the
-- one answer that needs neither the process tree nor a guess.
T["opencode.resolve"]["takes the session id from the environment when one is exported"] = function()
  vim.env.OPENCODE_SESSION_ID = "ses_old"
  local result = resolve_opencode(opencode_opts())
  expect.equality(result.rung, "$OPENCODE_SESSION_ID")
  expect.equality(result.session_id, "ses_old")
end

T["opencode.resolve"]["takes the session id from a pointer naming this process tree"] = function()
  vim.env.OPENCODE_PID = "4242"
  local root = tmpdir()
  write_pointer(root, 4242, { pids = { 4242 }, sessionID = "ses_old", directory = "/proj", ts = 1 })
  local result = resolve_opencode(opencode_opts { state_root = root })
  expect.equality(result.rung, "pointer file")
  expect.equality(result.session_id, "ses_old")
end

-- The newest root session started in this directory since the TUI did. `ses_old` predates it,
-- `ses_child` is a subagent's, and `ses_other` belongs to another project.
T["opencode.resolve"]["guesses the newest session in the cwd when nothing points at one"] = function()
  vim.env.OPENCODE_PID = "4242"
  local result = resolve_opencode(opencode_opts())
  expect.equality(result.rung, "guessed")
  expect.equality(result.session_id, "ses_new")
end

-- A daemon serving two TUIs in one directory writes pointers no pid chain reaches. Declining
-- to a labelled guess is what keeps a wrong conversation from being shown as a certain one.
T["opencode.resolve"]["guesses when the only pointer names another process tree"] = function()
  vim.env.OPENCODE_PID = "4242"
  local root = tmpdir()
  local orphan = vim.loop.os_getppid() + 1000000
  write_pointer(root, orphan, { pids = { orphan }, sessionID = "ses_old", directory = "/proj", ts = 1 })
  local result = resolve_opencode(opencode_opts { state_root = root })
  expect.equality(result.rung, "guessed")
end

T["opencode.resolve"]["fills the session's id, which detection leaves holding a pid"] = function()
  vim.env.OPENCODE_SESSION_ID = "ses_old"
  local session = session_for "opencode"
  session.session_id = "4242"
  resolve_opencode(opencode_opts(), session)
  expect.equality(session.session_id, "ses_old")
end

-- Without the TUI's start time the guess has no floor, and the newest session in the directory
-- may be one from last week.
T["opencode.resolve"]["fails soft rather than guessing with no start time to measure from"] = function()
  local result = resolve_opencode(opencode_opts())
  expect.equality(result.ok, false)
  expect.equality(type(result.err), "string")
end

---A `vim.system` stand-in whose process reports `obj`.
local function fake_spawn(obj)
  return function(_, _, on_exit)
    on_exit(obj)
    return obj
  end
end

T["opencode.resolve"]["fails soft on every way the read can go wrong"] = function()
  vim.env.OPENCODE_SESSION_ID = "ses_old"
  local cases = {
    ["missing sqlite3"] = {
      spawn = function()
        error "ENOENT: no such file or directory"
      end,
    },
    ["missing database"] = { db_path = tmpdir() .. "/absent.db" },
    ["non-zero exit"] = { spawn = fake_spawn { code = 1, stderr = "file is not a database" } },
    ["unparseable output"] = { spawn = fake_spawn { code = 0, stdout = "not json" } },
    ["no rows"] = { spawn = fake_spawn { code = 0, stdout = "" } },
  }
  local soft = {}
  for name, override in pairs(cases) do
    local result = resolve_opencode(opencode_opts(override))
    soft[name] = result.ok == false and type(result.err) == "string"
  end
  expect.equality(soft, {
    ["missing sqlite3"] = true,
    ["missing database"] = true,
    ["non-zero exit"] = true,
    ["unparseable output"] = true,
    ["no rows"] = true,
  })
end

T["opencode.resolve"]["declines a session belonging to another tool"] = function()
  local result, claimed = resolve_opencode(opencode_opts(), session_for "claude-code")
  expect.equality(claimed, nil)
  expect.equality(result, nil)
end

return T
