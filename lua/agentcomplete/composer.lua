---The prompt window as a page to write on: soft-wrapped prose with a hanging indent, and none of
---the gutter a code buffer carries.
---
---Every option is set window-local for the prompt buffer (`:setlocal`), saved first and restored
---on detach, so another buffer opened in the same window gets the user's settings back.
---@class AgentComplete.Composer
local M = {}

---What the prompt window sets. Statusline and winbar are left to the user and their plugins.
local OPTIONS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  -- The inset off the window's edge, matching the pane's. Padding on the text instead would land
  -- in every yank.
  statuscolumn = "  ",
  cursorline = false,
  wrap = true,
  linebreak = true,
  breakindent = true,
  -- Wrapped list items hang under their text rather than their bullet, using the markdown
  -- ftplugin's 'formatlistpat'.
  breakindentopt = "list:-1",
  smoothscroll = true,
}

---@class AgentComplete.Composer.State
---@field win integer Window the options were set on.
---@field saved table<string, any> Each option's local value before attach.
---@field group integer Augroup the cleanup autocmd lives in.

---@type table<integer, AgentComplete.Composer.State>
M._composers = {}

---@param win integer
---@param option string
---@param value any
local function set_local(win, option, value)
  vim.api.nvim_set_option_value(option, value, { win = win, scope = "local" })
end

---Apply the page's options to the window showing `buf`. Idempotent per buffer — a second attach
---would save this module's own values as the ones to restore — and a no-op when the buffer is on
---no screen.
---@param buf integer
function M.attach(buf)
  local win = vim.fn.bufwinid(buf)
  if M._composers[buf] or win == -1 then
    return
  end
  local saved = {}
  for option, value in pairs(OPTIONS) do
    saved[option] = vim.api.nvim_get_option_value(option, { win = win, scope = "local" })
    set_local(win, option, value)
  end

  local group =
    vim.api.nvim_create_augroup("AgentCompleteComposer_" .. buf, { clear = true })
  M._composers[buf] = { win = win, saved = saved, group = group }

  -- The options live with the buffer in its window, so a wiped buffer takes them along; all
  -- there is left to release is the record of them.
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    buffer = buf,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
      M._composers[buf] = nil
    end,
  })
end

---Restore the window's options.
---@param buf integer
function M.detach(buf)
  local state = M._composers[buf]
  if not state then
    return
  end
  M._composers[buf] = nil
  pcall(vim.api.nvim_del_augroup_by_id, state.group)
  if
    vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_win_get_buf(state.win) == buf
  then
    for option, value in pairs(state.saved) do
      set_local(state.win, option, value)
    end
  end
end

return M
