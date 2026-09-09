---The pane the agent's last message is shown in: the windows it is built from and the
---autocmds that keep them in step with the prompt beside it. Nothing here knows what a
---resolver is — it is handed text and a name to put in the border.
---
---A split cannot carry a border and a float alone would cover the prompt rather than sit
---beside it, so the pane is both: a split reserves the room and takes the resize, and a float
---drawn inside it carries the frame.
---@class AgentComplete.Context.Pane
local M = {}

---The pane's two windows, per prompt buffer: `win` is the float holding the message, `spacer`
---the split it sits over.
---@type table<integer, { win: integer, spacer: integer }>
M._panes = {}

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

---Share of the terminal's width the pane takes when it sits beside the prompt. The reply being
---composed is the work; the message beside it is reference for that work.
local PANE_WIDTH = 0.4

---Reserve the room the float fills: this split holds the space and takes the resize.
---@param host integer Window showing the prompt.
---@param vertical boolean
---@return integer
local function reserve(host, vertical)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, false, {
    split = vertical and "right" or "below",
    win = host,
  })
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = false
  vim.wo[win].winbar = ""
  -- Not 'winfixwidth': fixing the width makes the prompt absorb the whole of a terminal
  -- resize rather than shrinking with it. `place` reasserts the pane's share instead.
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

---A key as the footer shows it: `<C-f>` becomes `^F`, and anything that is not a plain
---control key stays as Vim spells it.
---@param lhs string
---@return string
local function label(lhs)
  local keys = vim.fn.keytrans(vim.api.nvim_replace_termcodes(lhs, true, true, true))
  return (keys:gsub("^<C%-(%u)>$", "^%1"))
end

---Up before down, so the footer reads in the direction the message does.
local SCROLL_ACTIONS = { "scroll_up", "scroll_down" }

---The frame: who is speaking, how to read past the first screen, and that you cannot answer
---here. Two-tone so the agent's name reads first and the labels recede into the border.
---@param resolver string
---@param rung string|nil
---@param keys table<string, string|false>|nil
---@return vim.api.keyset.win_config
local function chrome(resolver, rung, keys)
  local title = { { "─ ", "FloatBorder" }, { resolver, "Title" } }
  if rung then
    title[#title + 1] = { " · " .. rung, "Comment" }
  end
  title[#title + 1] = { " · last message ", "Comment" }
  local scrolls = {}
  for _, action in ipairs(SCROLL_ACTIONS) do
    local lhs = keys and keys[action]
    if lhs then
      scrolls[#scrolls + 1] = label(lhs)
    end
  end
  local hint = #scrolls > 0 and (table.concat(scrolls, "/") .. " scroll · read-only") or "read-only"
  return {
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "left",
    footer = { { "─ ", "FloatBorder" }, { hint, "Comment" }, { " ─", "FloatBorder" } },
    footer_pos = "right",
  }
end

---@class AgentComplete.Context.Pane.Built
---@field buf integer Prompt buffer the pane belongs to.
---@field group integer Augroup the pane's autocmds live in.
---@field host integer Window showing the prompt.
---@field win integer Float holding the message.
---@field spacer integer Split the float is drawn over.
---@field min_width integer Terminal width at or above which the pane sits beside the prompt.
---@field on_close fun() What dismissing the pane means to its owner.

---Wire the pane to the windows around it.
---@param pane AgentComplete.Context.Pane.Built
local function follow(pane)
  local group, host, win, spacer = pane.group, pane.host, pane.win, pane.spacer
  local beside = vim.o.columns >= pane.min_width
  local placing = false

  local function valid()
    return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_is_valid(spacer)
  end

  ---Re-place the pane for the terminal as it is now: beside the prompt while there is width
  ---for both, beneath it once there is not. Guarded against its own resizes, which raise the
  ---very events that call it.
  local function place()
    if placing or not valid() then
      return
    end
    placing = true
    -- Guarded so a raise mid-resize cannot leave the flag set and the pane frozen where it is.
    pcall(function()
      local wanted = vim.o.columns >= pane.min_width
      if wanted ~= beside then
        beside = wanted
        vim.api.nvim_win_set_config(spacer, { split = beside and "right" or "below", win = host })
      end
      if beside then
        vim.api.nvim_win_set_width(spacer, math.floor(vim.o.columns * PANE_WIDTH))
      end
      vim.api.nvim_win_set_config(win, geometry(spacer))
    end)
    placing = false
  end

  ---On into the message when the cursor arrives from outside, back out to the prompt when it
  ---arrives from the message — which is every window move that leaves the float, since they
  ---all land on the spacer first.
  local function pass_through_spacer()
    if not valid() or vim.api.nvim_get_current_win() ~= spacer then
      return
    end
    local onward = vim.fn.win_getid(vim.fn.winnr "#") == win and host or win
    if vim.api.nvim_win_is_valid(onward) then
      vim.api.nvim_set_current_win(onward)
    end
  end

  local function mark_focus()
    if valid() then
      vim.wo[win].cursorline = vim.api.nvim_get_current_win() == win
    end
  end

  place()
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, { group = group, callback = place })
  vim.api.nvim_create_autocmd("WinEnter", { group = group, callback = pass_through_spacer })
  vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, { group = group, callback = mark_focus })
  -- The pane is chrome the prompt owns, so it goes when the prompt does — and on `QuitPre`,
  -- before the quit resolves, so the prompt window is the last one standing and `:q` returns
  -- the reader to the agent instead of stranding them in a message they cannot reply to.
  vim.api.nvim_create_autocmd("QuitPre", { group = group, buffer = pane.buf, callback = pane.on_close })
  -- Every window the pane is built from is a way out of it.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = { tostring(win), tostring(spacer), tostring(host) },
    callback = pane.on_close,
  })
end

---@class AgentComplete.Context.Pane.Options
---@field group integer Augroup the pane's autocmds live in.
---@field text string Message to show.
---@field min_width integer Terminal width at or above which the pane sits beside the prompt.
---@field resolver string Name shown in the border.
---@field rung? string Which step of the resolver's chain produced the session, shown beside its name.
---@field keys? table<string, string|false> Prompt-buffer keys that page the pane, by action; `false` disables one.
---@field on_close fun() Called for every route out of the pane the pane itself sees.

---Build the pane beside `buf`. Vertical at or above `min_width`, horizontal below it.
---@param buf integer Prompt buffer the pane belongs to.
---@param opts AgentComplete.Context.Pane.Options
---@return integer|nil win nil when `buf` is on no screen to split from.
function M.open(buf, opts)
  local host = vim.fn.bufwinid(buf)
  if host == -1 then
    return nil
  end
  local spacer = reserve(host, vim.o.columns >= opts.min_width)

  local pane_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[pane_buf].bufhidden = "wipe"
  local win_config = vim.tbl_extend("error", geometry(spacer), chrome(opts.resolver, opts.rung, opts.keys))
  local win = vim.api.nvim_open_win(pane_buf, false, win_config)

  -- Contents and filetype after the window, not before: window-local options are set against
  -- whichever window is current, so a filetype set while the pane has none sends every
  -- ftplugin and FileType autocmd to the prompt window and leaves the pane unrendered.
  vim.api.nvim_buf_set_lines(pane_buf, 0, -1, false, vim.split(opts.text, "\n"))
  vim.bo[pane_buf].modifiable = false
  vim.bo[pane_buf].filetype = "markdown"
  for option, value in pairs(PANE_OPTIONS) do
    vim.wo[win][option] = value
  end

  M._panes[buf] = { win = win, spacer = spacer }
  follow {
    buf = buf,
    group = opts.group,
    host = host,
    win = win,
    spacer = spacer,
    min_width = opts.min_width,
    on_close = opts.on_close,
  }
  return win
end

---Close the pane's windows and forget them. The augroup its autocmds live in belongs to the
---caller, which is what `on_close` exists to tell.
---@param buf integer
function M.close(buf)
  local pane = M._panes[buf]
  if not pane then
    return
  end
  -- Cleared first: closing either window fires `WinClosed`, which routes back here.
  M._panes[buf] = nil
  for _, win in ipairs { pane.win, pane.spacer } do
    pcall(vim.api.nvim_win_close, win, true)
  end
end

return M
