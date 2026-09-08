---A read-only pane showing the agent's last message beside its prompt buffer.
---
---Resolution is registry-based, mirroring `agentcomplete.detect`: each agent CLI registers a
---resolver, and this module asks for the last message the same way regardless of which tool
---launched it. Resolution is callback-shaped because a resolver may have to ask the tool's
---own CLI for the answer; the Claude Code one happens to finish synchronously, and reports
---through `cb` anyway so an asynchronous sibling drops in without changing the contract.
---
---The module splits the way `highlight.lua` does: `format`, `header`, and `log` are the
---editor-state-free core the tests drive directly, and `open`/`pane`/`close` are the glue.
---@class AgentComplete.Context
local M = {}

---@class AgentComplete.Context.Result
---@field ok boolean Whether the message was resolved.
---@field resolver string Name of the resolver that reported.
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
---@field session_id? string
---@field transcript? string
---@field bytes? integer Size of the resolved message.
---@field err? string Why no pane opened.

---What resolution produced, per prompt buffer. Read by `diagnostics.collect`.
---@type table<integer, AgentComplete.Context.State>
M._state = {}

---Pane window, per prompt buffer.
---@type table<integer, integer>
M._panes = {}

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
---outruns `FORMAT_TIMEOUT_MS` yields the raw text: the pane never fails over formatting, and
---never blocks the editor on it either — this runs on the main loop as the prompt opens.
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

---The pane's one-line title: which agent the message came from, and which session.
---Reads the result rather than the session, so a resolver that reports its session id without
---writing it back still titles the pane correctly.
---@param result AgentComplete.Context.Result
---@return string
function M.header(result)
  return "# " .. result.resolver .. " — last message (" .. tostring(result.session_id) .. ")"
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

---Open the read-only pane beside `buf`. The split follows the terminal's width, and so does
---the option that fixes its size — `winfixwidth` has no meaning on a horizontal split.
---@param buf integer Prompt buffer the pane belongs to.
---@param text string
---@param min_width integer Terminal width at or above which the split goes vertical.
---@return integer|nil win nil when `buf` is not on screen to split from.
function M.pane(buf, text, min_width)
  local host = vim.fn.bufwinid(buf)
  if host == -1 then
    return nil
  end
  local vertical = vim.o.columns >= min_width
  local pane_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[pane_buf].bufhidden = "wipe"
  vim.bo[pane_buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(pane_buf, 0, -1, false, vim.split(text, "\n"))
  vim.bo[pane_buf].modifiable = false

  local win = vim.api.nvim_open_win(pane_buf, false, { split = vertical and "right" or "below", win = host })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win][vertical and "winfixwidth" or "winfixheight"] = true
  M._panes[buf] = win
  return win
end

---Close the pane for `buf` and release everything `open` recorded for it.
---@param buf integer
function M.close(buf)
  local win = M._panes[buf]
  if win then
    -- Closing the prompt buffer can leave the pane as the only window, which Neovim refuses to
    -- close. An orphaned pane is a better outcome than quitting the editor out from under it.
    pcall(vim.api.nvim_win_close, win, true)
    M._panes[buf] = nil
  end
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
    M._state[buf] = { resolver = result.resolver, err = result.err }
    M.log(log_path, result.err or "resolution failed")
    return
  end
  M.pane(buf, M.header(result) .. "\n\n" .. format(result.text or ""), config.min_width)
  -- After the pane, so a raise from it leaves the error in `_state` rather than a success
  -- shape that tells a diagnostics reader the pane is on screen.
  M._state[buf] = {
    resolver = result.resolver,
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
  if not config.enabled or headless or M._augroups[buf] or has_editor_context(buf) then
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

  local claimed, err = M.resolve(session, function(result)
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
