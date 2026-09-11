---The pane the agent's last message is shown in: the windows it is built from, the keys that
---scroll them from the prompt beside it, and the autocmds that keep the three in step. Nothing
---here knows what a resolver is — it is handed text, a name for the border, and keys to map.
---
---A split cannot carry a border and a float alone would cover the prompt rather than sit
---beside it, so the pane is both: a split reserves the room and takes the resize, and a float
---drawn inside it carries the frame.
---@class AgentComplete.Context.Pane
local M = {}

---What the pane left behind, per prompt buffer: `win` is the float holding the message,
---`spacer` the split it sits over, and `keys` what `open` mapped on the prompt, so `close`
---removes exactly that without needing the configuration again.
---@type table<integer, { win: integer, spacer: integer, keys: string[] }>
M._panes = {}

---What the pane turns off beyond `style = "minimal"`, which already clears 'number',
---'relativenumber', 'cursorline', 'foldcolumn', 'spell' and 'list'. 'conceallevel' is the
---point of the pane rather than a detail of it: markdown markup exists to be edited, and this
---is the one markdown in the editor nobody will edit. The inset is a 'statuscolumn' rather
---than padding on the text, which would land in every yank and hide the markup from the
---parser that renders it. 'smoothscroll' lets the scroll keys step through a paragraph the
---pane wraps a row at a time, where Vim would otherwise skip it whole as one line.
local PANE_OPTIONS = {
  wrap = true,
  linebreak = true,
  smoothscroll = true,
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
  local shown = vim.fn.keytrans(vim.api.nvim_replace_termcodes(lhs, true, true, true))
  return (shown:gsub("^<C%-(%u)>$", "^%1"))
end

---The two ways to scroll the pane. Up before down, so the footer reads in the direction the
---message does.
local SCROLL = {
  { option = "scroll_up", keycode = vim.keycode "<C-y>", desc = "agentcomplete: scroll the last-message pane up" },
  { option = "scroll_down", keycode = vim.keycode "<C-e>", desc = "agentcomplete: scroll the last-message pane down" },
}

---@class AgentComplete.Context.Pane.Scroll
---@field lhs string Key to map on the prompt.
---@field keycode string What Vim scrolls the pane with.
---@field desc string How the mapping names itself.

---The scroll keys `keys` asks for, in footer order. One reading of the configuration, so the
---footer and the mappings cannot come to disagree about what is bound.
---@param keys AgentComplete.Context.Keys|nil
---@return AgentComplete.Context.Pane.Scroll[]
local function configured(keys)
  local active = {}
  for _, scroll in ipairs(SCROLL) do
    local lhs = keys and keys[scroll.option]
    if lhs then
      active[#active + 1] = { lhs = lhs, keycode = scroll.keycode, desc = scroll.desc }
    end
  end
  return active
end

---Give `lhs` back, but only while it is still the mapping `open` set. A neighbour that has
---remapped it since owns it now — blink.cmp does exactly that on the buffer's first
---`InsertEnter`, and deleting its mapping would strand the key: blink reinstates nothing,
---because its own re-apply stops as soon as any of its other mappings is still on the buffer.
---@param buf integer
---@param lhs string
local function unmap(buf, lhs)
  local wanted = vim.api.nvim_replace_termcodes(lhs, true, true, true)
  for _, mode in ipairs { "n", "i" } do
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
      local same = vim.api.nvim_replace_termcodes(map.lhs, true, true, true) == wanted
      if same and vim.startswith(map.desc or "", "agentcomplete:") then
        vim.keymap.del(mode, lhs, { buffer = buf })
      end
    end
  end
end

---Scroll `win` with `keycode`, leaving the window the reader is in current.
---
---Once the pane is gone the key is not ours: blink.cmp resolves the mapping it falls back to
---once, when it wires the buffer, so it goes on calling this for the buffer's life. Passing
---`lhs` through unmapped is what keeps it doing something rather than nothing.
---@param win integer
---@param keycode string
---@param lhs string The key the reader pressed.
local function scroll_pane(win, keycode, lhs)
  if not vim.api.nvim_win_is_valid(win) then
    return vim.api.nvim_feedkeys(vim.keycode(lhs), "n", false)
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! " .. keycode)
  end)
end

---The frame: who is speaking, how to read past the first screen, and that you cannot answer
---here. Two-tone so the agent's name reads first and the labels recede into the border.
---@param resolver string
---@param rung string|nil
---@param scrolls AgentComplete.Context.Pane.Scroll[]
---@return vim.api.keyset.win_config
local function chrome(resolver, rung, scrolls)
  local title = { { "─ ", "FloatBorder" }, { resolver, "Title" } }
  if rung then
    title[#title + 1] = { " · " .. rung, "Comment" }
  end
  title[#title + 1] = { " · last message ", "Comment" }
  local labels = vim.tbl_map(function(scroll)
    return label(scroll.lhs)
  end, scrolls)
  local hint = #labels > 0 and (table.concat(labels, "/") .. " scroll · read-only") or "read-only"
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
---@field keys? AgentComplete.Context.Keys Prompt-buffer keys that scroll the pane.
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
  -- Before the split: these are the first things here a bad `keys` value can raise from, and
  -- a raise once the split exists strands it — nothing owns it yet to close it.
  local scrolls = configured(opts.keys)
  local frame = chrome(opts.resolver, opts.rung, scrolls)
  local spacer = reserve(host, vim.o.columns >= opts.min_width)

  local pane_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[pane_buf].bufhidden = "wipe"
  local win_config = vim.tbl_extend("error", geometry(spacer), frame)
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

  -- On the prompt buffer, not the pane: the message has to be readable without leaving the
  -- reply.
  local mapped = vim.tbl_map(function(scroll)
    vim.keymap.set({ "n", "i" }, scroll.lhs, function()
      scroll_pane(win, scroll.keycode, scroll.lhs)
    end, { buffer = buf, desc = scroll.desc })
    return scroll.lhs
  end, scrolls)

  M._panes[buf] = { win = win, spacer = spacer, keys = mapped }
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

---Close the pane's windows, unmap the scroll keys from the prompt, and forget them. The
---augroup its autocmds live in belongs to the caller, which is what `on_close` exists to tell.
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
  if vim.api.nvim_buf_is_valid(buf) then
    for _, lhs in ipairs(pane.keys) do
      unmap(buf, lhs)
    end
  end
end

return M
