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

---The pane's two windows, per prompt buffer: `win` is the float holding the message, `spacer`
---the split it sits over.
---@type table<integer, { win: integer, spacer: integer }>
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

---What the pane turns off beyond `style = "minimal"`, which already clears 'number',
---'relativenumber', 'cursorline', 'foldcolumn', 'spell' and 'list'. 'conceallevel' is the
---point of the pane rather than a detail of it: markdown markup exists to be edited, and this
---is the one markdown in the editor nobody will edit. The inset is a 'statuscolumn' rather
---than padding on the text, which would land in every yank and hide the markup from the
---parser that renders it.
local PANE_OPTIONS = {
  wrap = true,
  linebreak = true,
  conceallevel = 3,
  concealcursor = "nc",
  signcolumn = "no",
  statuscolumn = "  ",
  winhighlight = "Normal:NormalFloat",
}

---Reserve the room the float fills. A split cannot carry a border and a float alone would
---cover the prompt rather than sit beside it, so the pane is both: this split holds the space
---and takes the resize, and the float draws inside it.
---@param host integer Window showing the prompt.
---@param vertical boolean
---@return integer
local function reserve(host, vertical)
  local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    split = vertical and "right" or "below",
    win = host,
  })
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = false
  vim.wo[win].winbar = ""
  vim.wo[win].winfixbuf = true
  return win
end

---The float's rectangle: inset a column so the split's separator and the border are not drawn
---against each other, and short of the full height so the bottom border stays on screen.
---@param spacer integer
---@return vim.api.keyset.win_config
local function geometry(spacer)
  return {
    relative = "win",
    win = spacer,
    row = 0,
    col = 1,
    width = math.max(1, vim.api.nvim_win_get_width(spacer) - 4),
    height = math.max(1, vim.api.nvim_win_get_height(spacer) - 2),
  }
end

---The frame: who is speaking, and that you cannot answer here. Two-tone so the agent's name
---reads first and the labels recede into the border.
---@param resolver string
---@return vim.api.keyset.win_config
local function chrome(resolver)
  return {
    style = "minimal",
    border = "rounded",
    title = { { "─ ", "FloatBorder" }, { resolver, "Title" }, { " · last message ", "Comment" } },
    title_pos = "left",
    footer = { { "─ ", "FloatBorder" }, { "read-only", "Comment" }, { " ─", "FloatBorder" } },
    footer_pos = "right",
  }
end

---Keep the pane in step with the windows around it: track the split it is drawn over, hand the
---cursor on when that split is entered, mark the message as focused, and take the whole pane
---down with the prompt.
---@param buf integer Prompt buffer.
---@param host integer Window showing the prompt.
---@param win integer Float holding the message.
---@param spacer integer Split the float is drawn over.
local function follow(buf, host, win, spacer)
  local grp = M._augroups[buf] or vim.api.nvim_create_augroup("AgentCompleteContext_" .. buf, { clear = false })
  local function valid()
    return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_is_valid(spacer)
  end

  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = grp,
    callback = function()
      if valid() then
        vim.api.nvim_win_set_config(win, geometry(spacer))
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
    group = grp,
    callback = function()
      if not valid() then
        return
      end
      -- The split only holds the room; landing in it means landing on an empty buffer exactly
      -- where the message appears to be.
      if vim.api.nvim_get_current_win() == spacer then
        vim.api.nvim_set_current_win(win)
      end
      vim.wo[win].cursorline = vim.api.nvim_get_current_win() == win
    end,
  })

  -- The pane is chrome the prompt owns, so it goes when the prompt does — and on `QuitPre`,
  -- before the quit resolves, so the prompt window is the last one standing and `:q` returns
  -- the reader to the agent instead of stranding them in a message they cannot reply to.
  vim.api.nvim_create_autocmd("QuitPre", {
    group = grp,
    buffer = buf,
    callback = function()
      M.close(buf)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = grp,
    pattern = { tostring(win), tostring(host) },
    callback = function()
      M.close(buf)
    end,
  })
end

---Open the read-only pane beside `buf`, framed and titled for `resolver`. Vertical at or above
---`min_width`, horizontal below it.
---@param buf integer Prompt buffer the pane belongs to.
---@param text string
---@param min_width integer Terminal width at or above which the pane opens as a vertical split.
---@param resolver string Name shown in the border.
---@return integer|nil win nil when `buf` is not on screen to split from.
function M.pane(buf, text, min_width, resolver)
  local host = vim.fn.bufwinid(buf)
  if host == -1 then
    return nil
  end
  local spacer = reserve(host, vim.o.columns >= min_width)

  local pane_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[pane_buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(pane_buf, false, vim.tbl_extend("error", geometry(spacer), chrome(resolver)))

  -- Contents and filetype after the window, not before: window-local options are set against
  -- whichever window is current, so a filetype set while the pane has none sends every
  -- ftplugin and FileType autocmd to the prompt window and leaves the pane unrendered.
  vim.api.nvim_buf_set_lines(pane_buf, 0, -1, false, vim.split(text, "\n"))
  vim.bo[pane_buf].modifiable = false
  vim.bo[pane_buf].filetype = "markdown"
  for option, value in pairs(PANE_OPTIONS) do
    vim.wo[win][option] = value
  end

  M._panes[buf] = { win = win, spacer = spacer }
  follow(buf, host, win, spacer)
  return win
end

---Close the pane for `buf` and release everything `open` recorded for it.
---@param buf integer
function M.close(buf)
  local pane = M._panes[buf]
  if pane then
    -- Cleared first: closing either window fires `WinClosed`, which routes back here.
    M._panes[buf] = nil
    for _, win in ipairs { pane.win, pane.spacer } do
      pcall(vim.api.nvim_win_close, win, true)
    end
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
  M.pane(buf, format(result.text or ""), config.min_width, result.resolver)
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
