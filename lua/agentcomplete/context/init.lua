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
---A resolver that throws is skipped rather than aborting the walk.
---@param session AgentComplete.Session
---@param cb fun(result: AgentComplete.Context.Result)
---@return string|nil name The claiming resolver, or nil when none took the session.
function M.resolve(session, cb)
  for _, resolver in ipairs(M.resolvers) do
    local ok, claimed = pcall(resolver.resolve, session, cb)
    if ok and claimed then
      return resolver.name
    end
  end
  return nil
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

---Pane window and teardown augroup, per prompt buffer.
---@type table<integer, { win: integer, augroup: integer }>
M._panes = {}

---Claude Code's own `externalEditorContext` renders the conversation into the prompt buffer
---above this line. Matched on the sentence rather than the full box-drawn delimiter, so a
---change to its padding cannot silently show the same message twice.
local DELIMITER = "Write your reply below this line"

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

---Pipe `text` through `rumdl fmt -`. A missing binary or a non-zero exit yields the raw text:
---the pane never fails over formatting.
---@param text string
---@param system? fun(cmd: string[], opts: table): table Defaults to `vim.system`; injected in tests.
---@return string
function M.format(text, system)
  system = system or vim.system
  local ok, proc = pcall(function()
    return system({ "rumdl", "fmt", "-" }, { stdin = text, text = true }):wait()
  end)
  if not ok or proc.code ~= 0 or type(proc.stdout) ~= "string" or proc.stdout == "" then
    return text
  end
  return proc.stdout
end

---The pane's one-line title: which agent the message came from, and which session.
---@param session AgentComplete.Session
---@param resolver string
---@return string
function M.header(session, resolver)
  return "# " .. resolver .. " — last message (" .. tostring(session.session_id) .. ")"
end

---Append a timestamped line to `path`, creating its directory. Silent on failure — the log
---exists to explain a missing pane, and cannot be allowed to become a second one.
---@param path string
---@param message string
---@param now? string Timestamp; defaults to the current local time.
function M.log(path, message, now)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local file = io.open(path, "a")
  if not file then
    return
  end
  file:write("[" .. (now or os.date "%Y-%m-%d %H:%M:%S") .. "] " .. message .. "\n")
  file:close()
end

---Open the read-only pane beside `buf`, wiring its teardown to that buffer's lifetime.
---The split follows the terminal's width, and so does the option that fixes its size —
---`winfixwidth` has no meaning on a horizontal split.
---@param buf integer Prompt buffer the pane belongs to.
---@param text string
---@param min_width integer Terminal width at or above which the split goes vertical.
---@return integer win
function M.pane(buf, text, min_width)
  local vertical = vim.o.columns >= min_width
  local pane_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[pane_buf].bufhidden = "wipe"
  vim.bo[pane_buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(pane_buf, 0, -1, false, vim.split(text, "\n"))
  vim.bo[pane_buf].modifiable = false

  local win = vim.api.nvim_open_win(pane_buf, false, { split = vertical and "right" or "below", win = 0 })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win][vertical and "winfixwidth" or "winfixheight"] = true

  local grp = vim.api.nvim_create_augroup("AgentCompleteContext_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
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
  M._panes[buf] = { win = win, augroup = grp }
  return win
end

---Close the pane for `buf` and release everything `open` recorded for it.
---@param buf integer
function M.close(buf)
  local pane = M._panes[buf]
  if pane then
    -- Closing the prompt buffer can leave the pane as the only window, which Neovim refuses to
    -- close. An orphaned pane is a better outcome than quitting the editor out from under it.
    pcall(vim.api.nvim_win_close, pane.win, true)
    pcall(vim.api.nvim_del_augroup_by_id, pane.augroup)
    M._panes[buf] = nil
  end
  M._state[buf] = nil
end

---@class AgentComplete.Context.Options
---@field enabled boolean Whether attaching opens the pane at all.
---@field min_width integer Terminal width at or above which the pane opens as a vertical split.

---Resolve the agent's last message for `buf` and show it beside the prompt.
---Every failure is soft: it lands in the log at `opts.log_path` and in `M._state[buf]`,
---and leaves the prompt buffer alone.
---@param buf integer
---@param session AgentComplete.Session
---@param config AgentComplete.Context.Options
---@param opts? { log_path?: string, headless?: boolean } Seams; both are derived from the editor when absent.
function M.open(buf, session, config, opts)
  opts = opts or {}
  local headless = opts.headless
  if headless == nil then
    headless = #vim.api.nvim_list_uis() == 0
  end
  if not config.enabled or headless or has_editor_context(buf) then
    return
  end

  -- Beside the project, not under `stdpath("log")`: the agent whose message failed to load is
  -- the one that has to read this, and it can only reach paths inside its own cwd.
  local log_path = opts.log_path or ((vim.loop.cwd() or vim.fn.getcwd()) .. "/.tmp/agentcomplete-context.log")

  local claimed = M.resolve(session, function(result)
    -- Guarded here rather than left to the registry's `pcall`: a raise from the pane would
    -- read there as "the resolver declined", and be logged as the wrong failure.
    local ok, err = pcall(function()
      if not result.ok then
        M._state[buf] = { resolver = result.resolver, err = result.err }
        M.log(log_path, result.err)
        return
      end
      M._state[buf] = {
        resolver = result.resolver,
        session_id = result.session_id,
        transcript = result.transcript,
        bytes = #result.text,
      }
      M.pane(buf, M.header(session, result.resolver) .. "\n\n" .. M.format(result.text), config.min_width)
    end)
    if not ok then
      M.log(log_path, "context pane failed: " .. tostring(err))
    end
  end)

  if not claimed then
    local err = "no context resolver for tool " .. tostring(session.tool)
    M._state[buf] = { err = err }
    M.log(log_path, err)
  end
end

return M
