---Token highlighting for agent prompt buffers.
---
---`@file` and `/skill` tokens are highlighted only when they actually resolve, so an
---uncolored token is how a typo shows itself before the prompt is sent. There is no
---"broken token" group — absence of highlight is the signal.
---
---Backend-agnostic: wired from `init.lua`'s attach/detach rather than from `backends/`,
---so it behaves identically under blink and native. The module splits the same way
---`backends/native.lua` does — `M.marks` is the editor-state-free core the tests drive
---directly, `M.repaint` and the autocmds are the glue around it.
---@class AgentComplete.Highlight
local M = {}

local sources = require "agentcomplete.sources"

---Extmark namespace for every token highlight this module applies. Namespaced to the
---module, not the plugin: `M.detach` clears it wholesale, so a namespace shared with a
---future feature would have that feature's marks deleted along with these.
M.ns = vim.api.nvim_create_namespace "agentcomplete.highlight"

---@type table<integer, AgentComplete.Session>
M._sessions = {}
---@type table<integer, integer>
M._augroups = {}
---@type table<integer, uv.uv_timer_t>
M._timers = {}

---Repaints coalesce on this many milliseconds per buffer. Unlike native completion's
---cursor-local parse, resolving `/` tokens walks every skill dir and reads frontmatter
---per skill — too much to redo on every keystroke.
local DEBOUNCE_MS = 100

---Define the two highlight groups. Idempotent, and safe to call from any buffer's attach.
---`default = true` so a user's own `nvim_set_hl` wins, and so the link itself survives the
---`:hi clear` a colorscheme change runs — which is why no `ColorScheme` autocmd is needed
---to re-establish them. A user's explicit override does *not* survive that clear, but
---restoring it is theirs to do, not ours to guess at.
function M.ensure_groups()
  vim.api.nvim_set_hl(0, "AgentCompleteSkill", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "AgentCompleteFile", { link = "Directory", default = true })
end

---Every `/` name the session resolves, as a set. An empty query matches everything, so
---one `sources.items` call yields the whole set — and inherits skills, commands, plugin
---namespacing, OpenCode's asynchronously-arriving `extra_skills`, hidden-built-in
---filtering, and the `sources.slash` toggle, with no second source of truth.
---@param session AgentComplete.Session
---@return table<string, true>
local function slash_names(session)
  local set = {}
  for _, it in ipairs(sources.items(session, { trigger = "/", query = "", start_col = 1 })) do
    set[it.insert_text] = true
  end
  return set
end

---Whether `name` names anything on disk, relative to the session cwd. Deliberately a
---superset of `scan.files`: directories and gitignored paths resolve, because what
---matters is that the agent will find the path, not that completion offered it.
---Absolute and `~` paths are normalized rather than joined to cwd.
---@param cwd string
---@param name string
---@return boolean
local function file_exists(cwd, name)
  local path = name:match "^[/~]" and vim.fs.normalize(name) or (cwd .. "/" .. name)
  return vim.loop.fs_stat(path) ~= nil
end

---@class AgentComplete.Mark
---@field row integer 0-based line index.
---@field col integer 0-based byte column of the token's first character.
---@field end_col integer 0-based byte column just past the token's last character.
---@field hl_group string Highlight group to apply across the whole token, trigger included.

---Marks for every resolving token in `lines`. Resolution happens here, at paint time,
---which is what makes a skill or file created mid-session highlight on the next repaint.
---The `/` set is built lazily — at most once per call, and only when a `/` token is
---actually present, since building it walks the skill dirs.
---@param session AgentComplete.Session
---@param lines string[]
---@return AgentComplete.Mark[]
function M.marks(session, lines)
  local enabled = session.sources or {}
  local out = {}
  local slash ---@type table<string, true>|nil
  for row, line in ipairs(lines) do
    for _, tok in ipairs(sources.tokens(line)) do
      local group
      -- An empty name never resolves, and short-circuiting here is what keeps a bare `/`
      -- — the first keystroke of every slash token — from walking each skill dir to look
      -- up "". A lone `@` would likewise fs_stat the cwd itself and match.
      if tok.name ~= "" then
        if tok.trigger == "/" and enabled.slash ~= false then
          slash = slash or slash_names(session)
          group = slash[tok.name] and "AgentCompleteSkill" or nil
        elseif tok.trigger == "@" and enabled.file ~= false then
          group = file_exists(session.cwd, tok.name) and "AgentCompleteFile" or nil
        end
      end
      if group then
        out[#out + 1] = { row = row - 1, col = tok.col, end_col = tok.end_col, hl_group = group }
      end
    end
  end
  return out
end

---Clear the namespace and re-apply marks for the buffer's current contents.
---@param buf integer
function M.repaint(buf)
  local session = M._sessions[buf]
  if not session or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, m in ipairs(M.marks(session, vim.api.nvim_buf_get_lines(buf, 0, -1, false))) do
    vim.api.nvim_buf_set_extmark(buf, M.ns, m.row, m.col, { end_col = m.end_col, hl_group = m.hl_group })
  end
end

---Coalesce repaints for `buf` onto a single per-buffer timer.
---@param buf integer
local function schedule(buf)
  local timer = M._timers[buf] or assert(vim.loop.new_timer())
  M._timers[buf] = timer
  timer:stop()
  timer:start(
    DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      M.repaint(buf)
    end)
  )
end

---@param buf integer
---@param session AgentComplete.Session
function M.attach(buf, session)
  M._sessions[buf] = session
  M.ensure_groups()
  local grp = vim.api.nvim_create_augroup("AgentCompleteHighlight_" .. buf, { clear = true })
  M._augroups[buf] = grp
  -- `InsertLeave` is not redundant with the two `TextChanged` events: edits made while the
  -- completion popup is open fire `TextChangedP`, so accepting a completion — the single
  -- most likely way a token appears — is caught on the way out of insert mode or not at all.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave", "BufEnter" }, {
    group = grp,
    buffer = buf,
    callback = function()
      schedule(buf)
    end,
  })
  -- Release per-buffer state when the buffer goes away (avoids stale sessions on bufnr reuse).
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = grp,
    buffer = buf,
    callback = function()
      M.detach(buf)
    end,
  })
  M.repaint(buf) -- an already-populated buffer paints without waiting for an edit
end

---@param buf integer
function M.detach(buf)
  local timer = M._timers[buf]
  if timer then
    timer:stop()
    timer:close()
    M._timers[buf] = nil
  end
  if M._augroups[buf] then
    pcall(vim.api.nvim_del_augroup_by_id, M._augroups[buf])
    M._augroups[buf] = nil
  end
  M._sessions[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

return M
