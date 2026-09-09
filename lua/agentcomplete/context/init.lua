---A read-only pane showing the agent's last message beside its prompt buffer.
---
---Resolution is registry-based, mirroring `agentcomplete.detect`: each agent CLI registers a
---resolver, and this module asks for the last message the same way regardless of which tool
---launched it. Resolution is callback-shaped because a resolver may have to ask the tool's
---own CLI for the answer; the Claude Code one happens to finish synchronously, and reports
---through `cb` anyway so an asynchronous sibling drops in without changing the contract.
---
---The module splits the way `highlight.lua` does: `format` and `log` are the editor-state-free
---core the tests drive directly, and `open`/`close` are the glue. The windows themselves are
---`context.pane`, which knows nothing about resolvers.
---@class AgentComplete.Context
local M = {}

local pane = require "agentcomplete.context.pane"

---@class AgentComplete.Context.Result
---@field ok boolean Whether the message was resolved.
---@field resolver string Name of the resolver that reported.
---@field rung? string Which step of a resolver's chain produced the session, when it has one.
---@field text? string The agent's last message, when `ok`.
---@field session_id? string Session the message was read from, when `ok`.
---@field transcript? string File the message was read from, when `ok`.
---@field err? string Why resolution failed, when not `ok`.

---@class AgentComplete.Context.Resolver
---@field name string
---@field resolve fun(session: AgentComplete.Session, cb: fun(result: AgentComplete.Context.Result), opts?: table): true|nil Non-nil ⇒ "this session is mine", and `cb` reports the outcome.

---@type AgentComplete.Context.Resolver[]
M.resolvers = {}

---Register a resolver. Order is significant: the first to claim a session wins.
---@param resolver AgentComplete.Context.Resolver
function M.register(resolver)
  table.insert(M.resolvers, resolver)
end

---Remove all registered resolvers.
function M.clear()
  M.resolvers = {}
end

---Offer `session` to each resolver in registration order until one claims it.
---A resolver that throws is skipped rather than aborting the walk — but its error is carried
---out when nothing else claims the session, so a crashing resolver is distinguishable from a
---missing one. They are opposite problems and the log has to say which.
---@param session AgentComplete.Session
---@param cb fun(result: AgentComplete.Context.Result)
---@param opts? table Resolver seams, passed through untouched.
---@return string|nil name The claiming resolver, or nil when none took the session.
---@return string|nil err Why a resolver raised, when none claimed.
function M.resolve(session, cb, opts)
  local raised
  for _, resolver in ipairs(M.resolvers) do
    local ok, claimed = pcall(resolver.resolve, session, cb, opts)
    if ok then
      if claimed then
        return resolver.name
      end
    elseif not raised then
      raised = resolver.name .. " raised: " .. tostring(claimed)
    end
  end
  return nil, raised
end

---@class AgentComplete.Context.State
---@field resolver? string Resolver that reported, when one claimed the session.
---@field rung? string Which step of the resolver's chain produced the session, when it has one.
---@field session_id? string
---@field transcript? string
---@field bytes? integer Size of the resolved message.
---@field err? string Why no pane opened.

---What resolution produced, per prompt buffer. Read by `diagnostics.collect`.
---@type table<integer, AgentComplete.Context.State>
M._state = {}

---Teardown augroup, per prompt buffer. Also the "context is attached here" guard: it is set
---before resolution starts, so a second `open` on the same buffer is a no-op even while an
---asynchronous resolver is still working.
---@type table<integer, integer>
M._augroups = {}

---Claude Code's own `externalEditorContext` renders the conversation into the prompt buffer
---above this line. Matched on the sentence rather than the full box-drawn delimiter, so a
---change to its padding cannot silently show the same message twice.
local DELIMITER = "Write your reply below this line"

---How long `rumdl` gets before the raw message is shown instead.
local FORMAT_TIMEOUT_MS = 1000

---@param buf integer
---@return boolean
local function has_editor_context(buf)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(DELIMITER, 1, true) then
      return true
    end
  end
  return false
end

---Pipe `text` through `rumdl fmt -`. A missing binary, a non-zero exit, or a formatter that
---outruns `FORMAT_TIMEOUT_MS` yields the raw text: the pane never fails over formatting. This
---runs on the main loop as the prompt opens, so the wait is bounded rather than left to hang.
---@param text string
---@param system? fun(cmd: string[], opts: table): table Defaults to `vim.system`; injected in tests.
---@return string
function M.format(text, system)
  system = system or vim.system
  local ok, proc = pcall(function()
    return system({ "rumdl", "fmt", "-" }, { stdin = text, text = true }):wait(FORMAT_TIMEOUT_MS)
  end)
  -- `wait(timeout)` returns nil rather than a result table when the timeout fires.
  if not ok or type(proc) ~= "table" or proc.code ~= 0 or type(proc.stdout) ~= "string" or proc.stdout == "" then
    return text
  end
  return proc.stdout
end

---Append a timestamped line to `path`, creating its directory. Guarded end to end, `mkdir`
---included: it raises on an unwritable cwd, and the log exists to explain a missing pane
---rather than to become a second failure in front of the user's prompt.
---@param path string
---@param message string
---@param now? string Timestamp; defaults to the current local time.
function M.log(path, message, now)
  pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local file = assert(io.open(path, "a"))
    file:write("[" .. (now or os.date "%Y-%m-%d %H:%M:%S") .. "] " .. message .. "\n")
    file:close()
  end)
end

---Close the pane for `buf` and release everything `open` recorded for it.
---@param buf integer
function M.close(buf)
  pane.close(buf)
  if M._augroups[buf] then
    pcall(vim.api.nvim_del_augroup_by_id, M._augroups[buf])
    M._augroups[buf] = nil
  end
  M._state[buf] = nil
end

---@class AgentComplete.Context.Options
---@field enabled boolean Whether attaching opens the pane at all.
---@field min_width integer Terminal width at or above which the pane opens as a vertical split.

---Build the pane for a resolved message, or record and log a resolver's failure.
---@param buf integer
---@param result AgentComplete.Context.Result
---@param config AgentComplete.Context.Options
---@param log_path string
---@param format fun(text: string): string
local function show(buf, result, config, log_path, format)
  if not result.ok then
    M._state[buf] = { resolver = result.resolver, rung = result.rung, err = result.err }
    M.log(log_path, result.err or "resolution failed")
    return
  end
  -- A resolver that had to choose between candidates says so here as well as in the border: the
  -- pane looks the same whichever conversation it found, and this is the record of which.
  if result.rung then
    M.log(log_path, result.resolver .. " resolved via " .. result.rung)
  end
  local win = pane.open(buf, {
    group = assert(M._augroups[buf], "pane built for an unattached buffer"),
    text = format(result.text or ""),
    min_width = config.min_width,
    resolver = result.resolver,
    rung = result.rung,
    on_close = function()
      M.close(buf)
    end,
  })
  if not win then
    M._state[buf] = { resolver = result.resolver, err = "prompt buffer is on no screen to split from" }
    M.log(log_path, M._state[buf].err)
    return
  end
  -- After the pane, so a raise from it leaves the error in `_state` rather than a success
  -- shape that tells a diagnostics reader the pane is on screen.
  M._state[buf] = {
    resolver = result.resolver,
    rung = result.rung,
    session_id = result.session_id,
    transcript = result.transcript,
    bytes = #(result.text or ""),
  }
end

---@class AgentComplete.Context.Seams
---@field log_path? string Where a failure is recorded; defaults to `<cwd>/.tmp/`.
---@field headless? boolean Whether there is no UI to split; read from the editor when absent.
---@field format? fun(text: string): string Defaults to `M.format`.
---@field resolver? table Passed through to the claiming resolver.

---Resolve the agent's last message for `buf` and show it beside the prompt. Idempotent per
---buffer. Every failure is soft: it lands in `M._state[buf]`, and — where something actually
---went wrong — in the log at `opts.log_path`. The prompt buffer is never disturbed.
---@param buf integer
---@param session AgentComplete.Session
---@param config AgentComplete.Context.Options
---@param opts? AgentComplete.Context.Seams
function M.open(buf, session, config, opts)
  opts = opts or {}
  local headless = opts.headless
  if headless == nil then
    headless = #vim.api.nvim_list_uis() == 0
  end
  -- `DELIMITER` is Claude Code's own sentence; gating the check on the tool is this module's
  -- one piece of per-tool knowledge, keeping a coincidental match elsewhere from reading as it.
  if
    not config.enabled
    or headless
    or M._augroups[buf]
    or (session.tool == "claude-code" and has_editor_context(buf))
  then
    return
  end

  -- `BufDelete`, not `BufUnload`: the latter also fires on `:edit!`, which would tear the pane
  -- down on a reload the buffer survives. Same pair `highlight.attach` listens on.
  local grp = vim.api.nvim_create_augroup("AgentCompleteContext_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = grp,
    buffer = buf,
    callback = function()
      -- Deferred: closing a window from inside the autocmd that announces its buffer is going
      -- away is refused by Neovim.
      vim.schedule(function()
        M.close(buf)
      end)
    end,
  })
  M._augroups[buf] = grp

  -- Beside the project rather than under `stdpath("log")`: the agent whose message failed to
  -- load has to find this without being told where to look.
  local log_path = opts.log_path or ((vim.loop.cwd() or vim.fn.getcwd()) .. "/.tmp/agentcomplete-context.log")
  local format = opts.format or M.format

  local reported = false
  local claimed, err = M.resolve(session, function(result)
    -- A resolver reports once, and only while this buffer is still attached. A second report
    -- would build a pane over the first and overwrite the record of its windows; one arriving
    -- after `close` would hang autocmds on an augroup nothing owns.
    if reported or M._augroups[buf] ~= grp then
      return
    end
    reported = true
    -- Guarded here rather than left to the registry's `pcall`: a raise from the pane would
    -- read there as "the resolver declined", and be logged as the wrong failure.
    local ok, failure = pcall(show, buf, result, config, log_path, format)
    if not ok then
      M._state[buf] = { resolver = result.resolver, err = "context pane failed: " .. tostring(failure) }
      M.log(log_path, M._state[buf].err)
    end
  end, opts.resolver)

  if not claimed then
    -- A tool with no resolver yet is not a failure, so it stays out of the log — which lives
    -- in the user's own project, and would otherwise gain a line per attach for every agent
    -- this plugin supports but cannot yet read a message from.
    local reason = err or ("no resolver for tool " .. tostring(session.tool))
    M._state[buf] = { err = reason }
    if err then
      M.log(log_path, err)
    end
  end
end

return M
