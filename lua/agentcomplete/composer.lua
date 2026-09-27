---The prompt window as a page to write on: soft-wrapped prose with an inset, and none of the
---gutter a code buffer carries. `layout` holds it at a readable measure; this module owns only
---the window's own options.
---
---Every option is set window-local for the prompt buffer (`:setlocal`), saved first and restored
---on detach, so another buffer opened in the same window gets the user's settings back.
---@class AgentComplete.Composer
local M = {}

---Columns of inset before the prompt's text. `layout` sizes the prompt window to the measure plus
---this, and it matches the pane's own frame, so stacked the reply shares the message's left edge.
M.INSET = 4

---What the prompt window turns off and on. The statusline is absent on purpose: it is the
---user's, and it is where their mode shows. The inset is a 'statuscolumn' rather than padding on
---the text, which would land in every yank.
local OPTIONS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  cursorline = false,
  statuscolumn = string.rep(" ", M.INSET),
  wrap = true,
  linebreak = true,
  breakindent = true,
  -- Wrapped list items hang under their text rather than their bullet, using the markdown
  -- ftplugin's 'formatlistpat'.
  breakindentopt = "list:-1",
  smoothscroll = true,
}

---Options plugins set on every window they attach to, re-set after this module has applied its
---own. The rest are left to the user: holding 'number' would undo their own `:set number` the
---moment they typed it.
local HELD = { "winbar", "statuscolumn" }

---When plugins set those. They do it from inside their own autocmds, which never fire
---`OptionSet` — autocmds do not nest — so the hold re-runs after these instead. They are
---dropbar's attach events, the one winbar plugin known to re-attach mid-session.
local REATTACH_EVENTS = { "BufEnter", "BufWinEnter", "BufWritePost", "FileType", "LspAttach" }

---The separators and end-of-buffer rows, blanked. Appended to the window's own 'fillchars',
---where a repeated item overrides the earlier one, so the user's other fill characters stay.
local BLANK_FILLCHARS = "eob: ,vert: ,horiz: ,horizup: ,horizdown: ,vertleft: ,vertright: ,verthoriz: "

---`current` with the separators and end-of-buffer rows blanked.
---@param current string The window's effective 'fillchars'.
---@return string
function M.fillchars(current)
  return current == "" and BLANK_FILLCHARS or (current .. "," .. BLANK_FILLCHARS)
end

---@class AgentComplete.Composer.State
---@field win integer Window the options were set on.
---@field saved table<string, any> Each option's local value before attach.
---@field group integer Augroup the hold lives in.

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
  local wanted = vim.tbl_extend("error", OPTIONS, {
    fillchars = M.fillchars(vim.api.nvim_get_option_value("fillchars", { win = win })),
    -- An empty local winbar falls back to a global one, so that is blanked rather than emptied.
    winbar = vim.go.winbar == "" and "" or " ",
  })
  local saved = {}
  for option, value in pairs(wanted) do
    saved[option] = vim.api.nvim_get_option_value(option, { win = win, scope = "local" })
    set_local(win, option, value)
  end

  local group = vim.api.nvim_create_augroup("AgentCompleteComposer_" .. buf, { clear = true })
  M._composers[buf] = { win = win, saved = saved, group = group }

  ---Set each held option back to the page's value where something else has changed it.
  local function hold()
    if not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf) then
      return
    end
    for _, option in ipairs(HELD) do
      if vim.wo[win][option] ~= wanted[option] then
        set_local(win, option, wanted[option])
      end
    end
  end

  -- Deferred past every other handler of the event, whichever order they were registered in.
  vim.api.nvim_create_autocmd(REATTACH_EVENTS, {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(hold)
    end,
  })
  -- For a set made outside any autocmd; a `:setglobal` leaves the prompt's own value alone.
  -- Setting an option from inside `OptionSet` does not fire it again, so this cannot loop.
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = HELD,
    callback = function()
      if vim.api.nvim_get_current_win() == win and vim.v.option_command ~= "setglobal" then
        hold()
      end
    end,
  })
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

---Restore the window's options and stop holding them.
---@param buf integer
function M.detach(buf)
  local state = M._composers[buf]
  if not state then
    return
  end
  M._composers[buf] = nil
  pcall(vim.api.nvim_del_augroup_by_id, state.group)
  if vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_win_get_buf(state.win) == buf then
    for option, value in pairs(state.saved) do
      set_local(state.win, option, value)
    end
  end
end

return M
