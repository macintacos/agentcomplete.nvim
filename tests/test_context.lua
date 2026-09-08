-- Tests for agentcomplete.context: the resolver registry, the Claude Code transcript
-- resolver (with its roots and subprocess injected, so no real `$HOME`, `ps`, or formatter
-- subprocess is touched), and the pane built around them.
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
  require("agentcomplete.context").register(stub("claude-code", result))
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
  local config = vim.api.nvim_win_get_config(assert(pane_win()))
  local function chunks(parts)
    return table.concat(vim.tbl_map(function(part)
      return part[1]
    end, parts))
  end
  expect.equality(config.border[1], "╭")
  expect.equality(chunks(config.title):find("claude-code", 1, true) ~= nil, true)
  expect.equality(chunks(config.footer):find("read-only", 1, true) ~= nil, true)
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
  context.open(buf, session_for "claude-code", { enabled = true, min_width = 160 }, with_resolver(ok_result "hello"))
  expect.equality(context._state[buf].resolver, "claude-code")
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

return T
