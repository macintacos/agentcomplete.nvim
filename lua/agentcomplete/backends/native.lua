---Native completion adapter.
---
---Maps the shared core's normalized items to Neovim complete-items and drives
---them through a buffer-local `completefunc` plus a `TextChangedI` autotrigger
---that calls `vim.fn.complete()`. Prefix filtering is done by the core (vim does
---not fuzzy-filter completefunc results).
---@class AgentComplete.Backend.Native
local M = {}

local sources = require "agentcomplete.sources"

---@type table<integer, AgentComplete.Session>
M._sessions = {}
---@type table<integer, integer>
M._augroups = {}

---Pure mapping: items for a line + 0-based cursor column, as vim complete-items.
---@param session AgentComplete.Session
---@param line string
---@param col integer 0-based byte cursor column
---@return { start_col: integer, items: table[] }|nil
function M.completions(session, line, col)
  local ctx = sources.context(line, col)
  if not ctx then
    return nil
  end
  local items = {}
  for _, it in ipairs(sources.items(session, ctx)) do
    table.insert(items, {
      word = it.insert_text,
      abbr = it.label,
      menu = it.detail or "",
      kind = it.kind,
      icase = 1,
    })
  end
  return { start_col = ctx.start_col, items = items }
end

---`completefunc` implementation (0-based findstart column, per :h complete-functions).
---@param findstart integer
---@param _base string
---@return integer|table[]
function M.completefunc(findstart, _base)
  local buf = vim.api.nvim_get_current_buf()
  local session = M._sessions[buf]
  if not session then
    return findstart == 1 and -3 or {}
  end
  local _, col = unpack(vim.api.nvim_win_get_cursor(0))
  local res = M.completions(session, vim.api.nvim_get_current_line(), col)
  if findstart == 1 then
    return res and res.start_col or -3
  end
  return res and res.items or {}
end

---Autotrigger: open the popup as soon as a trigger context exists.
---@param buf integer
function M._autotrigger(buf)
  if M._sessions[buf] == nil or vim.fn.pumvisible() == 1 then
    return
  end
  local _, col = unpack(vim.api.nvim_win_get_cursor(0))
  local res = M.completions(M._sessions[buf], vim.api.nvim_get_current_line(), col)
  if res and #res.items > 0 then
    -- complete() column is 1-based; guard against textlock/re-entrancy errors.
    pcall(vim.fn.complete, res.start_col + 1, res.items)
  end
end

---@param buf integer
---@param session AgentComplete.Session
function M.attach(buf, session, _config)
  M._sessions[buf] = session
  vim.bo[buf].completefunc = "v:lua.require'agentcomplete.backends.native'.completefunc"
  vim.bo[buf].completeopt = "menuone,noselect" -- buffer-local; never touches the global
  local grp = vim.api.nvim_create_augroup("AgentCompleteNative_" .. buf, { clear = true })
  M._augroups[buf] = grp
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = grp,
    buffer = buf,
    callback = function()
      M._autotrigger(buf)
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
end

---@param buf integer
function M.detach(buf)
  if M._augroups[buf] then
    pcall(vim.api.nvim_del_augroup_by_id, M._augroups[buf])
    M._augroups[buf] = nil
  end
  M._sessions[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].completefunc = ""
  end
end

return M
