---The pane the agent's last message is shown in: a plain split next to the prompt, the keys that
---scroll it from the prompt, and the autocmds that close it with the prompt. Nothing here knows
---what a resolver is — it is handed text, a buffer name, and keys to map.
---@class AgentComplete.Context.Pane
local M = {}

---What the pane left behind, per prompt buffer: `win` is the pane's window, and `keys` what
---`open` mapped on the prompt, so `close` removes exactly that without the configuration again.
---@type table<integer, { win: integer, keys: string[] }>
M._panes = {}

---Every value is named, because a split copies the options of the window it splits.
---`style = "minimal"` would be shorter, but it is documented for floats only, and the plugin
---supports 0.10. 'conceallevel' is the point of the pane, not a detail of it: markdown markup
---exists to be edited, and this is the one markdown in the editor nobody will edit.
---'smoothscroll' lets the scroll keys step through a paragraph the pane wraps a row at a time,
---where Vim would otherwise skip it whole as one line.
local PANE_OPTIONS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  -- The inset off the window's edge, matching the prompt's.
  statuscolumn = "  ",
  cursorline = false,
  cursorcolumn = false,
  colorcolumn = "",
  spell = false,
  list = false,
  breakindent = false,
  wrap = true,
  linebreak = true,
  smoothscroll = true,
  conceallevel = 3,
  concealcursor = "nc",
  winfixbuf = true,
}

---The two ways to scroll the pane.
local SCROLL = {
  {
    option = "scroll_up",
    keycode = vim.keycode("<C-y>"),
    desc = "agentcomplete: scroll the last-message pane up",
  },
  {
    option = "scroll_down",
    keycode = vim.keycode("<C-e>"),
    desc = "agentcomplete: scroll the last-message pane down",
  },
}

---@class AgentComplete.Context.Pane.Scroll
---@field lhs string Key to map on the prompt.
---@field keycode string What Vim scrolls the pane with.
---@field desc string How the mapping names itself.

---The scroll keys `keys` binds; one set to `false` is left out.
---@param keys AgentComplete.Context.Keys|nil
---@return AgentComplete.Context.Pane.Scroll[]
local function configured(keys)
  local active = {}
  for _, scroll in ipairs(SCROLL) do
    local lhs = keys and keys[scroll.option]
    if lhs then
      assert(
        type(lhs) == "string",
        ("context.keys.%s must be a key or false"):format(scroll.option)
      )
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
  for _, mode in ipairs({ "n", "i" }) do
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

---@param resolver string
---@param rung string|nil
---@return string
local function buffer_name(resolver, rung)
  return "agentcomplete://" .. resolver .. (rung and ("/" .. rung) or "")
end

---@class AgentComplete.Context.Pane.Built
---@field buf integer Prompt buffer the pane belongs to.
---@field group integer Augroup the pane's autocmds live in.
---@field host integer Window showing the prompt.
---@field win integer Window showing the message.
---@field on_close fun() What dismissing the pane means to its owner.

---Close the pane when the prompt quits or either window closes.
---@param pane AgentComplete.Context.Pane.Built
local function follow(pane)
  local group, host, win = pane.group, pane.host, pane.win

  -- The pane goes with the prompt, and on `QuitPre` before the quit resolves: left standing, it
  -- would keep `:q` from returning the reader to the agent, stranding them in a message they
  -- cannot reply to.
  vim.api.nvim_create_autocmd(
    "QuitPre",
    { group = group, buffer = pane.buf, callback = pane.on_close }
  )
  -- Closing either window, by any route, takes the pane down.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = { tostring(win), tostring(host) },
    callback = pane.on_close,
  })
end

---@class AgentComplete.Context.Pane.Options
---@field group integer Augroup the pane's autocmds live in.
---@field text string Message to show.
---@field min_width integer Terminal width at or above which the pane sits beside the prompt.
---@field stacked? "above"|"below" Edge it takes below that width; defaults to `above`.
---@field resolver string Name the pane's buffer carries.
---@field rung? string Which step of the resolver's chain produced the session; appended to the name.
---@field keys? AgentComplete.Context.Keys Prompt-buffer keys that scroll the pane.
---@field on_close fun() Called for every route out of the pane the pane itself sees.

---Split the pane off `buf`: to its right at or above `min_width` columns, otherwise on the
---`stacked` edge.
---@param buf integer Prompt buffer the pane belongs to.
---@param opts AgentComplete.Context.Pane.Options
---@return integer|nil win nil when `buf` is on no screen to split from.
function M.open(buf, opts)
  -- `configured` first: it is where a bad `keys` value raises, and a raise once the split
  -- exists strands it — nothing owns it yet to close it.
  local scrolls = configured(opts.keys)
  local host = vim.fn.bufwinid(buf)
  if host == -1 then
    return nil
  end
  local side = vim.o.columns >= opts.min_width and "right" or (opts.stacked or "above")
  local pane_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[pane_buf].bufhidden = "wipe"
  -- ponytail: a second prompt with the same resolver gets an unnamed pane (E95); suffix the
  -- prompt's buffer number if that matters.
  pcall(vim.api.nvim_buf_set_name, pane_buf, buffer_name(opts.resolver, opts.rung))
  local topline = vim.api.nvim_win_call(host, vim.fn.winsaveview).topline
  local win = vim.api.nvim_open_win(pane_buf, false, { split = side, win = host })
  -- 'splitkeep' scrolls a window a stacked split shortens.
  vim.api.nvim_win_call(host, function()
    vim.fn.winrestview({ topline = topline })
  end)

  -- Contents and filetype after the window, not before: window-local options are set against
  -- whichever window is current, so a filetype set while the pane has none sends every
  -- ftplugin and FileType autocmd to the prompt window and leaves the pane unrendered.
  vim.api.nvim_buf_set_lines(pane_buf, 0, -1, false, vim.split(opts.text, "\n"))
  vim.bo[pane_buf].modifiable = false
  vim.bo[pane_buf].filetype = "markdown"
  for option, value in pairs(PANE_OPTIONS) do
    vim.api.nvim_set_option_value(option, value, { win = win, scope = "local" })
  end

  -- On the prompt buffer, not the pane: the message has to be readable without leaving the
  -- reply.
  local mapped = vim.tbl_map(function(scroll)
    vim.keymap.set({ "n", "i" }, scroll.lhs, function()
      scroll_pane(win, scroll.keycode, scroll.lhs)
    end, { buffer = buf, desc = scroll.desc })
    return scroll.lhs
  end, scrolls)

  M._panes[buf] = { win = win, keys = mapped }
  follow({
    buf = buf,
    group = opts.group,
    host = host,
    win = win,
    on_close = opts.on_close,
  })
  return win
end

---Close the pane's window, unmap the scroll keys from the prompt, and forget them. The augroup
---its autocmds live in belongs to the caller, which is what `on_close` exists to tell.
---@param buf integer
function M.close(buf)
  local pane = M._panes[buf]
  if not pane then
    return
  end
  -- Cleared first: closing the window fires `WinClosed`, which routes back here.
  M._panes[buf] = nil
  pcall(vim.api.nvim_win_close, pane.win, true)
  if vim.api.nvim_buf_is_valid(buf) then
    for _, lhs in ipairs(pane.keys) do
      unmap(buf, lhs)
    end
  end
end

return M
