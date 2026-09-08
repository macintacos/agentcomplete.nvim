-- Tests for agentcomplete.context: the Claude Code transcript resolver (with its roots and
-- subprocess injected, so no real `$HOME` and no real `ps` are touched).
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

return T
